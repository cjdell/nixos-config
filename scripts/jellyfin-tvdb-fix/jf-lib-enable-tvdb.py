#!/usr/bin/env python3
"""jf-lib-enable-tvdb.py — make sure "TheTVDB" is an enabled metadata fetcher
for the TV libraries.

THE ROOT CAUSE this fixes: when the TheTVDB plugin is absent (e.g. it was
removed at some point), Jellyfin prunes it from every library's TypeOptions
fetcher list. Re-installing the plugin does NOT put it back. Result:
TvdbEpisodeProvider is never invoked, and remote-search Apply + FullRefresh
silently do nothing (log line: "Missing Episode Fetcher not enabled ...").
This script re-adds it (episodes: as FIRST fetcher, ahead of TMDb/OMDb whose
stale ids are usually what re-poisoned the match in the first place).

Usage:
  JF_API_KEY=... ./jf-lib-enable-tvdb.py [--dry]
Env:
  JF_URL  default http://127.0.0.1:8096
"""
import json
import os
import sys
import urllib.request

BASE = os.environ.get("JF_URL", "http://127.0.0.1:8096")
KEY = os.environ.get("JF_API_KEY", "")
FETCHER = "TheTVDB"


def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method,
                               headers={"X-Emby-Token": KEY,
                                        "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=60) as resp:
        raw = resp.read()
        return resp.status, (json.loads(raw) if raw else None)


def main():
    dry = "--dry" in sys.argv
    st, vfs = req("GET", "/Library/VirtualFolders")
    if st != 200:
        sys.exit(f"GET /Library/VirtualFolders -> {st}")
    for vf in vfs:
        if vf.get("CollectionType") not in ("tvshows", None):
            continue
        lo = vf["LibraryOptions"]
        changed = False
        for to in lo.get("TypeOptions", []):
            cur = to.setdefault("MetadataFetchers", [])
            if FETCHER in cur:
                order_changed = False
                if to["Type"] == "Episode" and cur[0] != FETCHER:
                    cur.remove(FETCHER)
                    cur.insert(0, FETCHER)
                    order_changed = True
                if cur != to.get("MetadataFetcherOrder"):
                    to["MetadataFetcherOrder"] = list(cur)
                    order_changed = order_changed or True
                changed = changed or order_changed
                continue
            if to["Type"] == "Episode":
                cur.insert(0, FETCHER)
            else:
                cur.append(FETCHER)
            to["MetadataFetcherOrder"] = list(cur)
            changed = True
        print(f"library {vf['Name']!r} ({vf.get('CollectionType')}): "
              + ("needs update" if changed else "already ok"))
        for to in lo.get("TypeOptions", []):
            print("   ", to["Type"], "->", to["MetadataFetchers"])
        if changed and not dry:
            st, _ = req("POST", "/Library/VirtualFolders/LibraryOptions",
                        {"Id": vf["ItemId"], "LibraryOptions": lo})
            print("    POST LibraryOptions ->", st)
    if dry:
        print("(dry run, nothing posted)")


if __name__ == "__main__":
    main()
