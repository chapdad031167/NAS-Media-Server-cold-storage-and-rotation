# nas-media-automation

[![CI](https://github.com/chapdad031167/NAS-Media-Server-cold-storage-and-rotation/actions/workflows/ci.yml/badge.svg)](https://github.com/chapdad031167/NAS-Media-Server-cold-storage-and-rotation/actions/workflows/ci.yml)
[![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen)](https://www.shellcheck.net/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Automation scripts for a home NAS media server running Plex, Sonarr, Radarr,
and qBittorrent. Duplicate detection, torrent folder cleanup after seeding,
and a **cold storage pipeline** that identifies aged media via the Radarr and
Sonarr APIs and rotates it to a USB archive drive with checksum-verified
moves.

## The problem

A 22 TB storage pool sitting at **83% capacity**, growing weekly, with manual
cleanup that stopped scaling somewhere around "I'll deal with it this
weekend." Three specific leaks:

1. **Duplicates** — quality upgrades left two copies of the same movie
   (a 720p and the 1080p that replaced it) scattered across the library.
2. **Torrent leftovers** — finished torrents whose payload had long been
   imported into the library were still holding a full copy in the download
   folder after seeding ended.
3. **Cold media** — movies and ended TV shows nobody had touched in a year,
   occupying prime hot-pool space while a perfectly good USB archive drive
   sat idle.

## The scripts

| Script | What it does |
|---|---|
| [`scripts/duplicate_cleanup.sh`](scripts/duplicate_cleanup.sh) | Finds movies with multiple video files for the same title **and year** (including a `.mkv`/`.mp4` pair), keeps the largest (highest quality), flags the rest. |
| [`scripts/torrent_cleanup.sh`](scripts/torrent_cleanup.sh) | Compares the torrent download folders against the media library; deletes only confirmed-imported items. Unmatched and still-downloading items are never touched. |
| [`scripts/torrent_cleanup_api.py`](scripts/torrent_cleanup_api.py) | The safer successor: removes finished torrents **through the qBittorrent Web API** (client state always matches the disk — no broken seeds), and only once the seeding goal (ratio or seed-time) is met *and* the import is confirmed. |
| [`scripts/cold_storage_scan.py`](scripts/cold_storage_scan.py) | Read-only scanner. Queries Radarr (movies) and Sonarr (TV) — and optionally Tautulli watch history — and writes a JSON candidate list of media eligible for cold storage. Nothing is moved here. |
| [`scripts/cold_storage_cycle.sh`](scripts/cold_storage_cycle.sh) | Consumes the candidate JSON and moves each item to the USB archive with rsync copy → checksum verify → delete source, records it in the archive manifest, then unmonitors it in Radarr/Sonarr (optionally repointing its path so it stays visible). Can archive oldest-first until a pool-capacity target is met. |
| [`scripts/cold_storage_restore.sh`](scripts/cold_storage_restore.sh) | The way back: verified move from the archive to the hot pool, re-monitored in Radarr/Sonarr via the manifest. Cold storage is a rotation, not a one-way trip. |

See [docs/architecture.md](docs/architecture.md) for the decision rules and
the full operational flow.

## Safety design

These scripts delete and move terabytes of data, so the safety rails came
first:

- **Dry-run by default.** Every destructive script runs in report-only mode
  unless explicitly invoked with `--run`. There is no way to delete or move
  anything by accident.
- **Kids-content hard exclusion.** Anything under the `/kids/` or `/kidstv/`
  root folders is excluded from cold storage *before any other rule runs* —
  age, size, and protection status are never even consulted. Kids re-watch
  everything; nothing of theirs leaves the hot pool.
- **Protected franchise list.** ~70 franchise substrings (Star Wars, MCU, the
  Halloween/horror canon, …) that stay hot regardless of age or size. It's
  config, not code — edit the list in `cold_storage_scan.py` to taste.
- **Verified moves.** The cycle script replaced a bare `mv` with
  rsync copy → checksum verify → delete source. A move interrupted mid-copy
  is resumed and re-verified on the next run, never silently skipped.
- **Manual trigger for destruction.** Scanning runs on cron; moving and
  deleting only ever happens when a human passes `--run`.
- **Free-space preflight.** The cycle aborts before touching anything if the
  archive drive can't hold the whole candidate set plus 5% headroom.
- **Watched guard (optional).** With Tautulli configured, anything played
  within `WATCHED_GUARD_DAYS` (default 180) is never archived — release age
  says "old", watch history says "still loved", and the second signal wins.
- **Staleness guard.** The cycle refuses to `--run` from a candidate
  snapshot older than `CANDIDATE_MAX_AGE_DAYS` (default 7), and skips any
  item whose on-disk size grew >20% since the scan (quality-upgrade signal).
- **Lock files.** Every script takes an exclusive `flock`, so an overlapping
  cron run can't walk the same file tree twice.
- **Archive manifest.** Every verified move or restore appends a JSON line
  to a manifest that lives on the cold drive itself — a searchable index of
  what's archived, where it came from, and its Radarr/Sonarr id.

## Setup

Requirements: bash 4+, Python 3.8+ (stdlib only), rsync, and Radarr/Sonarr v3
API access.

### Quick install (on the NAS)

```bash
git clone https://github.com/chapdad031167/NAS-Media-Server-cold-storage-and-rotation.git
cd NAS-Media-Server-cold-storage-and-rotation
bash install.sh
```

The installer checks prerequisites, creates a locked-down (`600`)
`config.env` from the template — it **never overwrites** an existing one —
walks you through the core settings (paths, Radarr/Sonarr URLs and API
keys), syntax-verifies every script, and finishes with a health check.
Useful variants:

```bash
bash install.sh --dir /volume1/docker/scripts/nas-media-automation  # install elsewhere
bash install.sh --yes       # non-interactive: keep placeholders, edit config.env later
bash install.sh --doctor    # change nothing: re-verify paths + API connectivity anytime
```

`--doctor` is also the first thing to run when something misbehaves — it
confirms the library paths exist, the cold drive is mounted, and that
Radarr/Sonarr (and Tautulli, if configured) actually answer with your keys.

### Manual setup

```bash
# Create your private config (git-ignored)
cp config.env.example config.env
vi config.env   # fill in NAS paths, Radarr/Sonarr URLs and API keys

# Everything defaults to dry run — safe to try immediately
bash scripts/duplicate_cleanup.sh
bash scripts/torrent_cleanup.sh
python3 scripts/torrent_cleanup_api.py
python3 scripts/cold_storage_scan.py
bash scripts/cold_storage_cycle.sh
bash scripts/cold_storage_restore.sh            # list what's archived

# When (and only when) the dry-run report looks right:
bash scripts/duplicate_cleanup.sh --run
bash scripts/cold_storage_restore.sh "heat" --run   # bring one back
```

Optional integrations, all off by default (see `config.env.example`):
Tautulli watched guard (`TAUTULLI_URL` + `TAUTULLI_API_KEY`), push
notifications (`NTFY_URL` / `DISCORD_WEBHOOK_URL`), capacity-target
archiving (`POOL_TARGET_PCT`), and archived-media visibility
(`UPDATE_ARR_PATHS` — see [docs/architecture.md](docs/architecture.md)).

Typical cron setup (scan automatically, execute manually):

```cron
# Weekly cold-storage scan, Sunday 03:00 — read-only
0 3 * * 0  python3 /path/to/scripts/cold_storage_scan.py
```

### Running the tests

```bash
python3 -m pip install pytest
python3 -m pytest tests/ -v          # unit tests (all API calls mocked)
bash tests/shell/test_dry_run.sh     # integration tests on a fixture tree
shellcheck scripts/*.sh              # lint
```

## Lessons learned

**Filesystem timestamps lie after a migration.** The first version of the
cold storage scanner used file `mtime` to decide what was "old". Then the
library was bulk-migrated to a new volume — and every single file's mtime
became *today*. The entire library instantly read as brand new and the
scanner found zero candidates, forever.

The fix was to stop trusting the filesystem entirely and ask Radarr for the
**TMDB release date** instead, with a fallback chain
(`digitalRelease` → `physicalRelease` → `inCinemas` → release year). A
movie's release date never changes, no matter how many times the bytes move
between disks. TV uses the analogous Sonarr signal: `status == ended` plus
the `lastAired` date. As a bonus, missing metadata fails safe: no date means
age 0, which means *not* archived.

Other scars encoded in these scripts:

- `dirname | xargs basename` corrupts paths containing apostrophes
  (*Child's Play (1988)* broke duplicate grouping) — replaced with
  `basename "$(dirname ...)"`.
- Grouping duplicates by title alone treats *Halloween (1978)* and
  *Halloween (2007)* as copies of each other. The year is part of the group
  key, and there's a test to keep it that way.
- A bare `mv` across filesystems that dies mid-copy leaves a partial
  destination that a naive "destination exists → skip" check then skips
  forever. Moves are now rsync-copied, checksum-verified, resumed if
  partial, and only then is the source deleted.
- Archiving a monitored movie without unmonitoring it just makes Radarr
  cheerfully re-download it. The scan exports Radarr/Sonarr IDs so the cycle
  can unmonitor after each verified move.

## License

[MIT](LICENSE)
