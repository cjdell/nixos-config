# Jellyfin TV re-matching after a TheTVDB renumber (the DS9 fix, 2026-10-27)

**Symptom:** episodes show titles off by one (or a whole file shows only its
raw filename as name). **Cause:** TheTVDB re-edited the series' episode
numbering *underneath* an already-matched library. Jellyfin keeps the ids it
matched at import time, so everything matched before the edit is shifted.

This happened to the DS9 library on N100-NAS: Jellyfin matched it 2026-10-04/07
against pre-fix TVDB data; TVDB renumbered S01/S04/S07 around 2026-10-07
(splitting `Emissary` and `The Way of the Warrior` into `(1)/(2)`). Result:
S01 matched -1 shifted (E03 "Past Prologue" shown as *A Man Alone*), S04 -1
shifted from E03 up, the merged pilot unmatched-ish. 39 episodes in total.

**The filenames were never wrong.** Verified by reading the fade-to-black
title cards of 10 sampled files (frame extraction with ffmpeg over the first
~5 min; the quoted episode title appears within ~1 min after the opening
credits end; guest-star credits + scene content identify episodes even without
the card, e.g. "JEFFREY COMBS as Brunt" ⇒ *Body Parts*). So the fix is
re-matching, **not** renaming.

## The three things that have to be true for re-matching to work

1. **The TheTVDB plugin must be installed** — `GET /Plugins` must list it. In
   Oct 2026 this server *had no TVDB plugin* (its fetchers were matched in a
   pre-existing DB), so nothing could resolve TVDB ids. Install via API
   (`POST /Packages/Installed/TheTVDB`) and restart the service — on N100-NAS
   that is `sudo systemctl restart podman-jellyfin`, **never** `sudo podman
   restart jellyfin` (it stops the quadlet container and leaves the unit
   inactive).

2. **TheTVDB must be in the TV library's enabled metadata fetchers.** This was
   the actual blocker and is invisible everywhere but
   `GET /Library/VirtualFolders` → `LibraryOptions.TypeOptions[].MetadataFetchers`
   — when the plugin is gone, Jellyfin *prunes it from the library options* and
   does not restore it on reinstall. Symptom: Apply/Refresh return 204/204 and
   the log shows only `TvdbMissingEpisodeProvider: Missing Episode Fetcher not
   enabled` / `No series identity found`, and `Jellyfin.Plugin.Tvdb.Providers.
   TvdbEpisodeProvider` never appears. Fixed with
   `scripts/jellyfin-tvdb-fix/jf-lib-enable-tvdb.py` (episodes: put TheTVDB
   **first** — TMDb/OMDb then answer per their own (pre-fix) numbering, which
   is what re-corrupts things).

3. **Stale IMDb ids must be cleared in the same Apply.** A wrong-numbered
   `Imdb` id (left by the old match) makes OMDb re-apply the old title on every
   refresh even after the right Tvdb id is set — observed: item renamed back to
   "A Man Alone" *from* the old IMDB id. `Apply` deletes ids whose value is `""`.

## The working re-match flow (per episode)

1. `POST /Items/RemoteSearch/Apply/{itemId}?replaceAllImages=true`
   body `{"Name":"<live title>","ProviderIds":{"Tvdb":"<live id>","Imdb":""},
   "ParentIndexNumber":S,"IndexNumber":E,"SeriesName":"<series>"}` — merged
   double-length files (`SxxEyy-Ezz.mkv`, check with `ffprobe` ~90 min) also
   get `"IndexNumberEnd":ZZ`; the plugin then fetches both halves and combines
   the metadata (`The Way of the Warrior (1) / The Way of the Warrior (2)`).
2. Wait ~2 s (Apply only *stores* the ids — log line `Setting provider id's`,
   and its own queued refresh races its own save and does nothing useful).
3. `POST /Items/{itemId}/Refresh?MetadataRefreshMode=FullRefresh&ImageRefreshMode=Default&ReplaceAllMetadata=true`
4. Poll `GET /Items?Ids=…&UserId=…&Fields=Name` until the name matches.

Then a library rescan (`POST /Library/Refresh`) to pick up any rename
(the pilot file was renamed `S01E01 Emissary.mkv` → `S01E01-E02 Emissary.mkv`
to match live TVDB's split; Jellyfin reuses the item, watched state survives —
verify in DB: `SELECT PlayCount FROM UserData u JOIN BaseItems b ON b.Id=u.ItemId …`).

## Tools

All in `scripts/jellyfin-tvdb-fix/`, all parameterised (any show, any host):

| script | what it does |
| --- | --- |
| `jf-api-key.sh create <name>` / `delete <name>` | temporary API key inserted straight into `jellyfin.db` (`ApiKeys` table, via `sudo nix shell nixpkgs#sqlite`) — no login needed. **Delete it when done.** |
| `scrape-tvdb-season.sh <slug> <season...>` | live TVDB numbering → `SxxEyy\tid\ttitle` TSV (scrapes the public season pages; no TVDB account/key) |
| `jf-lib-enable-tvdb.py` | root-cause fix #2 (idempotent; `--dry` to inspect) |
| `jf-rematch.py --series-id <guid> --tsv live.tsv [--dry]` | applies the flow above to every file whose name disagrees with the live TSV, then verifies. Start with `--dry`. |

Typical session (on N100-NAS, against `http://127.0.0.1:8096`):

```sh
cd ~/nixos-config/scripts/jellyfin-tvdb-fix
export JF_API_KEY=$(./jf-api-key.sh create ds9-fix)
./scrape-tvdb-season.sh star-trek-deep-space-nine 1 2 3 4 5 6 7 > /tmp/live.tsv
./jf-lib-enable-tvdb.py --dry && ./jf-lib-enable-tvdb.py
SID=$(curl -s -H "X-Emby-Token: $JF_API_KEY" \
  "http://127.0.0.1:8096/Items?IncludeTypes=Series&SearchTerm=Deep%20Space%20Nine&Limit=1" \
  | nix shell nixpkgs#python3 -c 'import json,sys; print(json.load(sys.stdin)["Items"][0]["Id"])')
./jf-rematch.py --series-id "$SID" --tsv /tmp/live.tsv --dry
./jf-rematch.py --series-id "$SID" --tsv /tmp/live.tsv
curl -s -X POST -H "X-Emby-Token: $JF_API_KEY" http://127.0.0.1:8096/Library/Refresh
./jf-api-key.sh delete ds9-fix
```

## API gotchas (Jellyfin 10.11.11, learned the hard way)

* `MetadataRefreshMode` enum is `None|ValidationOnly|Default|FullRefresh` —
  `Always` 400s.
* `GET /Items/{id}` without `UserId` answers **400 "Error processing
  request."** (not a permissions hint); use `GET /Items?Ids=…&UserId=…` or the
  per-show `GET /Shows/{seriesId}/Episodes?Fields=Path,ProviderIds,Overview`
  (the Episodes endpoint returns ProviderIds but *not* Path unless asked).
* There is no `POST /Items/{itemId}/Identify` and no
  `/Items/RemoteSearch/Episode` in 10.11 — the UI's Identify dialog calls
  `GET /Items/RemoteSearch/Episode` variants that don't exist here; the working
  pair is **Apply + Refresh** only.
* `Apply` with a `Tvdb` id whose item still carries a stale `Imdb` id: the
  refresh follows the IMDb id. Always send `"Imdb":""` (and `"Tmdb":""`) to
  wipe them; TVDB's own episode record then re-adds the *correct* IMDb id.
* The live DB (`/srv/jellyfin/config/data/data/jellyfin.db`) is in WAL mode —
  a plain `cp` misses uncommitted rows; also copy `.db-wal` and
  `PRAGMA wal_checkpoint(TRUNCATE)` on the **copy** before reading. Item ids in
  SQL are dashed-uppercase GUIDs; API ids are dashed-lowercase.
* Plugin debug: add `"Jellyfin.Plugin.Tvdb": "Debug"` (and
  `System.Net.Http.HttpClient.Default*`) overrides to
  `/srv/jellyfin/config/logging.default.json` (back it up first!) and restart —
  that's what produced the `Missing Episode Fetcher not enabled` line that
  named the root cause.
* Merged episodes: the filename range `S01E01-E02` (like the existing
  `S04E01-E02` / `S07E25-E26` files) + `IndexNumberEnd` is what produces a
  single combined item; without it the second half shows as a missing episode.
* Cosmetic, unrelated: season folders display as "Season 1993" (year-named
  seasons from TVDB's aired-order).

## Verification checklist

* `GET /Shows/{sid}/Episodes?Fields=ProviderIds,Path,Overview&Limit=400` → every
  filename's `SxxEyy` title equals the live-TSV title (expect ~2 false
  positives: HTML-entity apostrophes like `It&#039;s` and the combined
  `What You Leave Behind` E25–E26).
* Watched progress survives (`UserData` rows join to the same item ids; check
  for orphans: `SELECT count(*) FROM UserData u LEFT JOIN BaseItems b ON
  b.Id=u.ItemId WHERE b.Id IS NULL AND (u.PlayCount>0 OR
  u.PlaybackPositionTicks>0)` → 0).
* `journalctl -u podman-jellyfin` has no Tvdb errors on a test FullRefresh.
* Temp API key deleted; `logging.default.json` restored from `.bak` + restart.
