# Changelog

All notable changes to this project are documented here. Versioning follows
[Semantic Versioning](https://semver.org/); dates are YYYY-MM-DD.

## [1.0.0] - 2026-07-09

Initial public release: a sanitized, tested, documented packaging of a
working home-NAS media automation stack.

### The pipeline

- **`cold_storage_scan.py` v2.4** — read-only scanner. Radarr (movies) and
  Sonarr (TV) via API; TMDB release-date aging with fallback chain
  (`digitalRelease` → `physicalRelease` → `inCinemas` → release year →
  fail-safe age 0); `/kids/` and `/kidstv/` hard exclusion; protected
  franchise list (`protected_franchises.txt`); optional Tautulli watched
  guard (`WATCHED_GUARD_DAYS`); writes a reviewable candidate JSON.
- **`cold_storage_cycle.sh` v2.4** — verified moves to the archive drive:
  rsync copy → checksum verify → delete source, resumes interrupted copies;
  free-space preflight; candidate staleness guard; per-item size re-verify;
  optional capacity target (`POOL_TARGET_PCT`, oldest-first); unmonitors in
  Radarr/Sonarr, optionally repointing paths (`UPDATE_ARR_PATHS`) so
  archived media stays visible; appends every move to the archive manifest.
- **`cold_storage_restore.sh` v1** — the way back: verified move to the hot
  pool, re-monitor via the manifest, ambiguous matches refused.
- **`duplicate_cleanup.sh` v1.4** — duplicate movie detection grouped by
  title AND year (Halloween 1978 ≠ 2007), across containers (.mkv/.mp4),
  keeps the largest file.
- **`torrent_cleanup.sh` v1.3** — filesystem cleanup of confirmed-imported
  torrent payloads; never touches unmatched or still-downloading items.
- **`torrent_cleanup_api.py` v1** — API successor: removes torrents through
  qBittorrent (client state always matches disk), gated on seeding goals
  (`QBT_MIN_RATIO` / `QBT_MIN_SEED_DAYS`) plus confirmed import.
- **`install.sh`** — guided installer (prereq checks, mode-600 config
  creation, never overwrites an existing config) and `--doctor` health
  check with live Radarr/Sonarr/Tautulli connectivity tests.

### Safety design

Dry-run by default everywhere with explicit `--run` for destructive
operations; kids-content exclusion evaluated before every other rule;
`flock` lock files; log retention; push notifications (ntfy/Discord) for
run summaries and fatal errors.

### Testing

92 pytest unit tests (all API layers mocked — no network in tests) and
64 shell integration checks on fixture trees; shellcheck-clean; CI on
every push and pull request.

[1.0.0]: https://github.com/chapdad031167/NAS-Media-Server-cold-storage-and-rotation/releases/tag/v1.0.0
