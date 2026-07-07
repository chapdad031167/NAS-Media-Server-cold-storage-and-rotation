# Architecture

## Overview

Two independent cleanup tools and a two-stage cold storage pipeline:

```
duplicate_cleanup.sh      torrent_cleanup.sh
      |                          |
      v                          v
   hot pool                 download folder
   (Movies/)                (Torrents/)

cold_storage_scan.py  ->  cold_storage_candidates.json  ->  cold_storage_cycle.sh
     (read-only,               (reviewable                      (verified move to
  Radarr/Sonarr APIs)           artifact)                        USB archive)
```

The scan and the cycle are deliberately separate programs joined by a JSON
file. The candidate list is a human-reviewable artifact: you can read it,
diff it against last month's, or hand-edit it before anything moves.

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
6. The translated host path actually exists on disk.

### TV (via Sonarr)

A series becomes a candidate only if **all** of the following hold:

1. Its root folder is **not** `/kidstv/` — hard exclusion.
2. Its title matches no protected franchise entry.
3. Sonarr status is **`ended`** — a show still airing is never archived,
   because Sonarr would keep writing new episodes into a moved folder.
4. It has actual files on disk (`sizeOnDisk > 0` and
   `episodeFileCount > 0`) — filters watchlist-only entries.
5. `lastAired` is **≥ `TV_MIN_AGE_DAYS`** ago (default 365 days).
6. The translated host path exists.

## The exclusion hierarchy

Checks run strictest-first; a hit short-circuits everything below it:

```
1. Kids root folder   (/kids/, /kidstv/)   <- absolute, checked first,
                                              not configurable by design
2. Protected franchise list                <- config: edit the PROTECTED
                                              list in cold_storage_scan.py
3. Mechanical thresholds                   <- config: size, age, status
4. Sanity gates                            <- file exists, path resolves
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
list over-protects on purpose.

## Operational flow

```
scan (cron, read-only)  ->  dry run  ->  verify  ->  execute (--run)  ->  repeat
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
   - rsync copy to the archive drive (resumes partial copies from
     interrupted earlier runs),
   - rsync `--checksum` comparison of source vs destination,
   - only on a clean verify: delete the source,
   - unmonitor the item in Radarr/Sonarr so it is not re-downloaded.
   A failed verify keeps the source and logs the diff; nothing is lost.
5. **Cron** — only the read-only scan is scheduled. Destructive steps are
   always a deliberate, manual `--run`.

## Configuration

All environment-specific values (URLs, API keys, paths, thresholds) live in
`config.env` (git-ignored; template in
[`config.env.example`](../config.env.example)). Bash scripts source it;
the Python scanner reads it directly and lets real environment variables
override it. Every script falls back to sensible defaults when a value is
absent — except secrets, which have no defaults and cause the dependent
feature to skip with a logged warning rather than fail the run.
