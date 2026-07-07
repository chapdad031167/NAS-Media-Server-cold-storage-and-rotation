# Architecture

## Overview

Cleanup tools plus a cold storage **rotation** (archive and restore):

```
duplicate_cleanup.sh      torrent_cleanup.sh / torrent_cleanup_api.py
      |                          |
      v                          v
   hot pool                 download folder / qBittorrent
   (Movies/)                (Torrents/)

cold_storage_scan.py  ->  cold_storage_candidates.json  ->  cold_storage_cycle.sh
 (read-only: Radarr/           (reviewable                      (verified move to
  Sonarr + Tautulli)            artifact)                        USB archive)
                                                                     |
                                                                     v
                     cold_storage_restore.sh  <-  cold_storage_manifest.jsonl
                      (verified move back,         (JSON-lines index living
                       re-monitor via API)          on the cold drive)
```

The scan and the cycle are deliberately separate programs joined by a JSON
file. The candidate list is a human-reviewable artifact: you can read it,
diff it against last month's, or hand-edit it before anything moves. The
manifest closes the loop: every verified move or restore appends one JSON
line (name, paths, size, Radarr/Sonarr id, timestamp), and because it lives
on the archive drive it travels with the archive.

## Decision rules

### Movies (via Radarr)

A movie becomes a cold storage candidate only if **all** of the following
hold, evaluated in this order:

1. Radarr reports a file on disk (`hasFile`).
2. Its root folder is **not** `/kids/` — hard exclusion, see below.
3. Its title matches no entry in the protected franchise list.
4. Size on disk is **≥ `MOVIE_MIN_SIZE_GB`** (default 2 GB). Small files
   aren't worth the archive round-trip.
5. Age is **≥ `MOVIE_MIN_AGE_DAYS`** (default 365 days), measured from the
   TMDB release date, *not* the filesystem:
   `digitalRelease` → `physicalRelease` → `inCinemas` → Jan 1 of the release
   year → age 0 (never archived) when no metadata exists at all.
6. **Watched guard** (optional): not played within `WATCHED_GUARD_DAYS`
   (default 180) according to Tautulli. Release age is a proxy for "nobody
   cares"; watch history is the ground truth, and it can veto the age rule.
   If Tautulli is unconfigured or unreachable the guard is skipped with a
   warning — behaviour is then identical to the pre-guard pipeline.
7. The translated host path actually exists on disk.

### TV (via Sonarr)

A series becomes a candidate only if **all** of the following hold:

1. Its root folder is **not** `/kidstv/` — hard exclusion.
2. Its title matches no protected franchise entry.
3. Sonarr status is **`ended`** — a show still airing is never archived,
   because Sonarr would keep writing new episodes into a moved folder.
4. It has actual files on disk (`sizeOnDisk > 0` and
   `episodeFileCount > 0`) — filters watchlist-only entries.
5. `lastAired` is **≥ `TV_MIN_AGE_DAYS`** ago (default 365 days).
6. **Watched guard** (optional, as for movies, matched by show title).
7. The translated host path exists.

## The exclusion hierarchy

Checks run strictest-first; a hit short-circuits everything below it:

```
1. Kids root folder   (/kids/, /kidstv/)   <- absolute, checked first,
                                              not configurable by design
2. Protected franchise list                <- config: protected_franchises.txt
3. Mechanical thresholds                   <- config: size, age, status
4. Watched guard (optional)                <- config: Tautulli last-played
5. Sanity gates                            <- file exists, path resolves
```

Two properties are load-bearing:

- **The kids check precedes the protected check.** A Batman movie filed
  under `/kids/` is reported as kids-excluded, not franchise-protected, so
  reclassifying the franchise list can never expose kids content.
- **Missing metadata fails safe.** No release date → age 0 → fails the age
  threshold → stays hot. The pipeline only archives what it can positively
  justify.

Franchise matching is case-insensitive substring matching, deliberately
loose: `"saw"` also protects *The Sawmill*. A false **keep** costs a few
gigabytes of hot storage; a false **archive** costs a family argument. The
list over-protects on purpose. It lives in
[`protected_franchises.txt`](../protected_franchises.txt) (one substring
per line, `#` comments) so taste changes don't require code changes; the
built-in copy in `cold_storage_scan.py` is the fallback if the file is
missing, and a test pins the two in sync.

## Operational flow

```
scan (cron, read-only)  ->  dry run  ->  verify  ->  execute (--run)  ->  repeat
                                                          |
                                          restore (--run) when needed
```

1. **Scan** — `cold_storage_scan.py` runs on a weekly cron. Read-only: it
   queries the APIs and writes `cold_storage_candidates.json`. It cannot
   move or delete anything.
2. **Dry run** — `cold_storage_cycle.sh` with no flags prints exactly what
   would move where, plus a free-space preflight. Same pattern for the two
   cleanup scripts.
3. **Verify** — a human reads the dry-run report. This step is the point of
   the whole design: the JSON artifact and the dry-run log exist to be read.
4. **Execute** — `--run` performs the destructive step:
   - refuse if the candidate snapshot is stale
     (`CANDIDATE_MAX_AGE_DAYS`) or an item grew >20% since the scan,
   - rsync copy to the archive drive (resumes partial copies from
     interrupted earlier runs),
   - rsync `--checksum` comparison of source vs destination,
   - only on a clean verify: delete the source,
   - unmonitor the item in Radarr/Sonarr so it is not re-downloaded
     (and, with `UPDATE_ARR_PATHS=true`, repoint its path — see below),
   - append the move to the archive manifest.
   A failed verify keeps the source and logs the diff; nothing is lost.
   With `POOL_TARGET_PCT` set, the cycle works oldest-first and stops as
   soon as pool usage is back at the target.
5. **Restore** — `cold_storage_restore.sh "<name>" --run` reverses a move
   with the same verified-copy pattern, re-monitors the item (id recovered
   from the manifest), and logs a `restored` manifest event. Ambiguous name
   matches are refused, and it shares a lock with the cycle script.
6. **Cron** — only the read-only scan is scheduled. Destructive steps are
   always a deliberate, manual `--run`. Every script pushes an end-of-run
   summary to `NTFY_URL`/`DISCORD_WEBHOOK_URL` when configured, so a failed
   cron scan is a phone buzz instead of a silent log file.

## Archived media visibility (UPDATE_ARR_PATHS)

By default an archived item is simply unmonitored: Radarr/Sonarr show it as
missing and Plex drops it. With `UPDATE_ARR_PATHS=true` the cycle instead
updates the item's path to its cold storage location (`moveFiles=false`,
since the files were already moved and verified), and the restore script
points it back on the way home. Setup:

1. Add `$COLD_ROOT/Movies` and `$COLD_ROOT/TV Shows` as **root folders** in
   Radarr and Sonarr, so the updated paths pass their health checks.
2. Optionally add those folders to Plex as an **"Archive" library** —
   archived media stays browsable and playable straight off the USB drive.

The manifest records `arr_path_updated` per item, so a mixed history
(some items archived before enabling this, some after) restores correctly.

## qBittorrent cleanup: filesystem vs API

`torrent_cleanup.sh` (v1) deletes payload directories off the disk. That is
only safe when qBittorrent no longer references them — otherwise the client
reports missing files and broken seeds (an H&R risk on private trackers).
`torrent_cleanup_api.py` is the preferred path: it asks qBittorrent to
remove the torrent *and* its data via the Web API, so client state and disk
never diverge, and it uses the client's own `ratio` / `seeding_time` to
respect seeding goals (`QBT_MIN_RATIO`, `QBT_MIN_SEED_DAYS`) before
considering a torrent removable. Import into the library is still confirmed
by folder matching, exactly like v1.

## Configuration

All environment-specific values (URLs, API keys, paths, thresholds) live in
`config.env` (git-ignored; template in
[`config.env.example`](../config.env.example)). Bash scripts source it;
the Python scanner reads it directly and lets real environment variables
override it. Every script falls back to sensible defaults when a value is
absent — except secrets, which have no defaults and cause the dependent
feature to skip with a logged warning rather than fail the run.
