#!/usr/bin/env python3
"""jf-rematch.py — re-match TV episodes against the LIVE TheTVDB numbering.

Every episode file is expected to carry its true number in its name
(SxxEyy.mkv / SxxEyy-Ezz for merged double-length episodes). We look up each
file's tag in a live-TVDB TSV (from scrape-tvdb-season.sh: SxxEyy<TAB>id<TAB>
title), and when Jellyfin's stored title disagrees, we

  1. POST /Items/RemoteSearch/Apply/{id}   {"ProviderIds":{"Tvdb":"<id>",
     "Imdb":""}, "ParentIndexNumber":S, "IndexNumber":E, ("IndexNumberEnd":E2),
     "SeriesName":..., "Year":...}
     - "Imdb":"" matters: a stale IMDb id lets OMDb re-apply the OLD numbering
       on every refresh (Apply itself sends ProviderIds verbatim; empty string
       deletes that id).
  2. POST /Items/{id}/Refresh?MetadataRefreshMode=FullRefresh&ReplaceAllMetadata=true
     Apply alone only stores ids ("Setting provider id's" log line) — the
     provider run must be triggered separately, and only AFTER Apply committed
     (the provider needs the item's Tvdb id visible, else:
     "No series identity found").
  3. Poll /Items?Ids=.. until the name matches the live title.

Usage:
  JF_API_KEY=... ./jf-rematch.py --series-id <jellyfin series guid> \
      --tsv live.tsv [--dry] [--only S01E03,S04E26]
Env:
  JF_URL  default http://127.0.0.1:8096
Find the series id with:
  curl -s -H "X-Emby-Token: $JF_API_KEY" "$JF_URL/Items?IncludeTypes=Series&SearchTerm=<name>"
"""
import argparse
import html
import json
import os
import re
import sys
import time
import urllib.request

BASE = os.environ.get("JF_URL", "http://127.0.0.1:8096")
KEY = os.environ.get("JF_API_KEY", "")


def req(method, path, body=None, timeout=90):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method,
                               headers={"X-Emby-Token": KEY,
                                        "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except Exception as e:  # noqa: BLE001 - report and let the caller retry/skip
        print("  request failed:", e)
        return -1, str(e)


def norm(s):
    """compare helper: strip punctuation/case/entities/curly quotes"""
    s = html.unescape(s or "")
    return re.sub(r"[^a-z0-9]", "", s.lower().replace("\u2019", "'"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--series-id", required=True)
    ap.add_argument("--tsv", required=True,
                    help="TSV from scrape-tvdb-season.sh")
    ap.add_argument("--user-id", default=None,
                    help="optional, for the verification read")
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--only", default=None,
                    help="comma list of SxxEyy tags to restrict to")
    ap.add_argument("--year", type=int, default=None,
                    help="series start year, sent in the Apply payload")
    args = ap.parse_args()
    only = set(args.only.split(",")) if args.only else None

    live = {}
    for ln in open(args.tsv):
        p = ln.rstrip().split("\t")
        if len(p) >= 3:
            live[p[0].strip()] = (int(p[1].strip()),
                                  " ".join(p[2:]).strip())

    st, d = req("GET", f"/Shows/{args.series_id}/Episodes"
                       "?Fields=ProviderIds,Overview,Path&Limit=400")
    if st != 200:
        sys.exit(f"episodes list -> {st}")

    fixes = []
    for x in d["Items"]:
        fn = x.get("Path", "").split("/")[-1]
        m = re.search(r"S(\d{2})E(\d{2})(?:-E(\d{2}))?", fn)
        if not m:
            print("no SxxEyy tag in filename, skipped:", fn)
            continue
        s, e1, e2 = int(m[1]), int(m[2]), m[3]
        tag = f"S{s:02d}E{e1:02d}"
        if only and tag not in only:
            continue
        want = live.get(tag)
        if not want:
            print(f"{tag}: not in live TSV, skipped ({fn})")
            continue
        cur, w = norm(x.get("Name")), norm(want[1])
        # merged files hold "Title A / Title B"; prefix match kills the
        # HTML-entity/false-positive noise (e.g. apostrophes)
        if cur and (w in cur or cur in w or w[:12] in cur):
            continue
        fixes.append((x["Id"], tag, s, e1, int(e2) if e2 else None,
                      want[0], want[1], x.get("Name")))

    print(f"{len(fixes)} items to fix")
    if args.dry:
        for f in fixes:
            print("WOULD:", f[1], f"|", f[7], "=>", f[6])
        return

    fails = []
    for (iid, tag, s, e1, end, tvdb, wanttitle, oldname) in fixes:
        payload = {"Name": wanttitle,
                   "ProviderIds": {"Tvdb": str(tvdb), "Imdb": ""},
                   "ParentIndexNumber": s, "IndexNumber": e1,
                   "SeriesName": d["Items"][0].get("SeriesName") or ""}
        if args.year:
            payload["Year"] = args.year
        if end:
            payload["IndexNumberEnd"] = end
        st, _ = req("POST", f"/Items/RemoteSearch/Apply/{iid}"
                          "?replaceAllImages=true", payload)
        if st != 204:
            print(tag, "APPLY FAIL", st)
            fails.append(tag)
            continue
        time.sleep(2)  # let Apply commit before the provider reads the ids
        req("POST", f"/Items/{iid}/Refresh?MetadataRefreshMode=FullRefresh"
                    "&ImageRefreshMode=Default&ReplaceAllMetadata=true"
                    "&ReplaceAllImages=false")
        ok = False
        for _ in range(8):
            time.sleep(5)
            st, dd = req("GET", f"/Items?Ids={iid}&Limit=1&Fields=Name")
            if st == 200 and dd["Items"]:
                nm = norm(dd["Items"][0]["Name"])
                if nm == norm(wanttitle) or norm(wanttitle) in nm:
                    ok = True
                    break
        print(("OK  " if ok else "FAIL"), tag, "|", oldname, "=>", wanttitle)
        if not ok:
            fails.append(tag)

    print("done. failures:", fails if fails else "none")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
