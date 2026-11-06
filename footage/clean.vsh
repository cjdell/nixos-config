#!/usr/bin/env vspipe
# clean.vsh — VapourSynth pipeline used by footage-clean.
#
# Driven entirely by FC_* environment variables (see footage-clean.sh):
#   FC_SRC           input file                                (required)
#   FC_DEINT         off | eedi3 | znedi3 | nnedi3cl | qtgmc   (default off)
#   FC_FIELD         tff | bff field order when deinterlacing (default tff)
#   FC_DENOISE       none | light | standard | strong | stronger (default standard)
#   FC_CHROMA_BLUR   0/1  extra chroma denoise (default 1 when denoising)
#   FC_CROP          WxH+X+Y  crop for overscan / head-switch junk (optional)
#   FC_ENDSEC        drop this many seconds worth of source frames off the
#                    END of the source clip before anything else (optional)
#   FC_ME_SEARCH     qtgmc motion-search algo 0..5 (default 3 = Hexes;
#                    4 = UMH, 5 = EPZS — survive periodic detail: fences,
#                    book spines, crib slats — that 3 locks a
#                    neighbour-period vector on)
#   FC_ME_SEARCHPARAM  search log-step (default 2; 3 pairs with EPZS)
#   FC_ME_RANGE      search range px (default: from the super padding ~16;
#                    raise to 24-32 for fast pans)
#   FC_ME_DIVIDE     1 = analyse 32x32 then divide to 16x16 (QTGMC 'divide')
#   FC_ME_RBLK       Recalculate block size (default 32; 16 keeps thin bars
#                    out of one block — big for fences)
#   FC_ME_BLEND      0/1 FlowInter field blend (default 1; 0 crisper pans,
#                    combs where the vectors fail)
#   FC_DEINT_DEGRAIN 0/1 temporal Degrain1 after the mc deinterlace
#                    (default 1; 0 = wrong vectors cannot smear over time)
#   FC_OSD_RECT     WxH+X+Y  keep the pure spatial bob inside this rect at
#                    the very end of the chain — for a burned-in camcorder
#                    timestamp, which any temporal pass turns to mush
#   FC_OSD_FEATHER  feather px on that rect edge (default 6)
#
# Order per the usual advice: crop -> deinterlace -> temporal denoise.
# Deinterlace modes:
#   eedi3/znedi3/nnedi3cl = 2x-rate neural-ish field interpolation
#       (what QTGMC's bob stage is; znedi3 is the fast CPU workhorse,
#        nnedi3cl offloads to OpenCL when an ICD exists)
#   qtgmc  = that bob plus motion-compensated deinterlacing + degrain —
#       a QTGMC-style chain in the filters this nixpkgs has (QTGMC.py
#       itself needs fmtconv + havsfunc, not packaged here).
import os
import sys

import vapoursynth as vs

core = vs.core


def env(key, default=""):
    return os.environ.get(key, default).strip()


src = env("FC_SRC")
if not src:
    raise SystemExit("clean.vsh: FC_SRC is not set")

deint = env("FC_DEINT", "off").lower()
denoise = env("FC_DENOISE", "standard").lower()
tff = env("FC_FIELD", "tff").lower() != "bff"
crop = env("FC_CROP", "")
chroma_blur = env("FC_CHROMA_BLUR", "1" if denoise not in ("", "none") else "0") == "1"

# qtgmc motion-estimation tuning + OSD protection (see README
# "Tuning the deinterlace"): every default reproduces the pre-tuning chain
# exactly, so existing renders are unchanged unless these are set.
me_search = int(env("FC_ME_SEARCH", "3"))
me_searchparam = int(env("FC_ME_SEARCHPARAM", "2"))
me_range = int(env("FC_ME_RANGE", "0"))
me_divide = env("FC_ME_DIVIDE", "0") == "1"
me_blend = env("FC_ME_BLEND", "1") == "1"
me_rblk = int(env("FC_ME_RBLK", "32"))
me_degrain = env("FC_DEINT_DEGRAIN", "1") == "1"
osd_rect = env("FC_OSD_RECT", "")
osd_feather = int(env("FC_OSD_FEATHER", "6"))

if deint not in ("off", "eedi3", "znedi3", "nnedi3cl", "qtgmc"):
    raise SystemExit(f"clean.vsh: bad FC_DEINT={deint}")
if denoise not in ("none", "light", "standard", "strong", "stronger"):
    raise SystemExit(f"clean.vsh: bad FC_DENOISE={denoise}")

clip = core.bs.VideoSource(source=src)

# --- end trim (footage-clean --to with --single-pass) -----------------------
# Trimming the SOURCE here — not just stopping rendering at the last frame —
# is what keeps the deinterlacer honest: the qtgmc-style chain leans on
# neighbouring frames, and a filter reading past the cut would blend a field
# of the discarded tail (tape blue, the operator's hand on the deck) into the
# final frame. A trimmed clip clamps the same way a physically cut file did.
endsec = env("FC_ENDSEC")
if endsec:
    n = int(round(float(endsec) * float(clip.fps)))
    if 0 < n < clip.num_frames:
        clip = clip[:n]

# --- crop (overscan, head-switch noise, black bars) -------------------------
if crop:
    wh, _, off = crop.partition("+")
    w, _x, h = wh.partition("x")
    xo, _p, yo = off.partition("+")
    w, h, x, y = int(w), int(h), int(xo), int(yo)
    if x + w > clip.width or y + h > clip.height:
        raise SystemExit(f"clean.vsh: crop {crop} outside {clip.width}x{clip.height}")
    clip = core.std.Crop(
        clip,
        left=x,
        top=y,
        right=clip.width - x - w,
        bottom=clip.height - y - h,
    )

# --- deinterlace ------------------------------------------------------------
def bob(cl):
    """Interlaced 25i -> progressive 50p via field interpolation."""
    if deint == "eedi3":
        # field 3 starts with top, 2 with bottom; doubles the frame rate.
        return core.eedi3m.EEDI3(cl, field=3 if tff else 2)
    if deint == "nnedi3cl":
        return core.nnedi3cl.NNEDI3CL(cl, field=3 if tff else 2, nsize=4, nnn=2)
    # default bob: znedi3 (CPU nnedi3). field=2/3 = double rate, starting
    # with bottom/top; full-rate interlaced input is consumed directly.
    return core.znedi3.nnedi3(cl, field=3 if tff else 2, nsize=4, nns=2)


if deint != "off":
    clip = core.std.SetFieldBased(clip, 1 if tff else 2)
    if deint == "qtgmc":
        # QTGMC-style: bob, motion vectors on the bob (analysis on a
        # blurred copy refined against the full-res super), then
        # FlowInter (mc deinterlace) + Degrain1. This mirrors
        # QTGMC(preset="slow") minus the source-matching / EEDI3 detail
        # passes, which need filters this nixpkgs does not carry.
        sp = bob(clip)
        pad = max(16, me_range)
        sup = core.mv.Super(sp, pel=2, hpad=pad, vpad=pad)
        sup_b = core.mv.Super(
            core.std.Convolution(sp, matrix=[1, 2, 1, 2, 4, 2, 1, 2, 1]),
            pel=2,
            hpad=pad,
            vpad=pad,
        )
        an = dict(
            delta=1, blksize=16, overlap=8,
            search=me_search, searchparam=me_searchparam,
        )
        rc = dict(
            blksize=me_rblk, overlap=me_rblk // 2,
            search=me_search, searchparam=me_searchparam,
        )
        if me_range:
            an["range"] = me_range
            rc["range"] = me_range
        if me_divide:
            an["divide"] = 1
        fw = core.mv.Analyse(sup_b, isb=False, **an)
        bw = core.mv.Analyse(sup_b, isb=True, **an)
        fw = core.mv.Recalculate(sup, fw, **rc)
        bw = core.mv.Recalculate(sup, bw, **rc)
        clip = core.mv.FlowInter(sp, sup, bw, fw, blend=me_blend)
        if me_degrain:
            clip = core.mv.Degrain1(clip, sup, bw, fw, thsad=16, thsadc=16)
        sp_bob = sp
    else:
        clip = bob(clip)

# --- temporal denoise (MDegrain) --------------------------------------------
# Preset table: (mvtools radius, thsad luma, thsadc chroma)
DENOISE_PRESETS = {
    "light": (1, 8, 6),
    "standard": (2, 10, 8),
    "strong": (3, 13, 10),
    "stronger": (3, 18, 13),
}

if denoise != "none":
    radius, thsad, thsadc = DENOISE_PRESETS[denoise]
    blk = 16
    ovl = 8
    sup = core.mv.Super(clip, pel=2, hpad=blk, vpad=blk)
    # ME on a blurred copy finds cleaner motion; vectors are then
    # refined (Recalculate) against the full-detail super.
    sup_b = core.mv.Super(
        core.std.Convolution(clip, matrix=[1, 2, 1, 2, 4, 2, 1, 2, 1]),
        pel=2,
        hpad=blk,
        vpad=blk,
    )
    vec_kwargs = {}
    for i in range(1, radius + 1):
        # mvtools API: delta is always positive; isb marks the direction
        # (mvfw -> isb=False, mvbw -> isb=True; deeper radii use larger deltas).
        for which, is_backward in (("mvfw", False), ("mvbw", True)):
            v = core.mv.Analyse(
                sup_b, delta=i, isb=is_backward, blksize=blk, overlap=ovl, search=3
            )
            v = core.mv.Recalculate(sup, v, blksize=blk * 2, overlap=blk, search=3)
            vec_kwargs[which if i == 1 else f"{which}{i}"] = v
    degrain = {1: core.mv.Degrain1, 2: core.mv.Degrain2, 3: core.mv.Degrain3}[radius]
    clip = degrain(clip, sup, thsad=thsad, thsadc=thsadc, **vec_kwargs)

# --- chroma denoise ---------------------------------------------------------
if chroma_blur:
    clip = core.std.BoxBlur(clip, planes=[1, 2], hradius=1, vradius=1)

# --- OSD protection ----------------------------------------------------------
# A camcorder date/time stamp is burned into the source field-by-field, so
# every temporal pass above treats the moving background under it as the
# moving subject and blends digits into scenery (and vice versa). Punch the
# untouched bob back in over the stamp region — last in the chain, so the
# denoise stage cannot re-smear it. Feathered so the boundary between the
# temporal and spatial treatments of the same background is not a hard line.
if osd_rect:
    if deint == "off":
        raise SystemExit("clean.vsh: FC_OSD_RECT needs --deint")
    if deint == "qtgmc":
        wh, _, off = osd_rect.partition("+")
        w, _x, h = wh.partition("x")
        xo, _p, yo = off.partition("+")
        w, h, x, y = int(w), int(h), int(xo), int(yo)
        if x < 0 or y < 0 or x + w > clip.width or y + h > clip.height:
            raise SystemExit(
                f"clean.vsh: osd rect {osd_rect} outside {clip.width}x{clip.height}"
            )
        n = clip.format.num_planes

        def blank(ww, hh, val):
            return core.std.BlankClip(
                width=ww, height=hh, length=clip.num_frames,
                format=clip.format, color=[val] * n,
            )

        hparts = []
        if x:
            hparts.append(blank(x, h, 0))
        hparts.append(blank(w, h, 255))
        if clip.width - x - w:
            hparts.append(blank(clip.width - x - w, h, 0))
        row = core.std.StackHorizontal(hparts)
        vparts = []
        if y:
            vparts.append(blank(clip.width, y, 0))
        vparts.append(row)
        if clip.height - y - h:
            vparts.append(blank(clip.width, clip.height - y - h, 0))
        mask = core.std.StackVertical(vparts)
        if osd_feather > 0:
            mask = core.std.BoxBlur(mask, hradius=osd_feather, vradius=osd_feather)
        clip = core.std.MaskedMerge(clip, sp_bob, mask)

clip.set_output(0)
