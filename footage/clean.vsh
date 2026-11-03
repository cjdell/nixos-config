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
        sup = core.mv.Super(sp, pel=2, hpad=16, vpad=16)
        sup_b = core.mv.Super(
            core.std.Convolution(sp, matrix=[1, 2, 1, 2, 4, 2, 1, 2, 1]),
            pel=2,
            hpad=16,
            vpad=16,
        )
        fw = core.mv.Analyse(sup_b, delta=1, isb=False, blksize=16, overlap=8, search=3)
        bw = core.mv.Analyse(sup_b, delta=1, isb=True, blksize=16, overlap=8, search=3)
        fw = core.mv.Recalculate(sup, fw, blksize=32, overlap=16, search=3)
        bw = core.mv.Recalculate(sup, bw, blksize=32, overlap=16, search=3)
        clip = core.mv.FlowInter(sp, sup, bw, fw, blend=True)
        clip = core.mv.Degrain1(clip, sup, bw, fw, thsad=16, thsadc=16)
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

clip.set_output(0)
