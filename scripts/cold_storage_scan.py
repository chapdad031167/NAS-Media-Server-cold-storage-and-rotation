#!/usr/bin/env python3
# ============================================================
# cold_storage_scan.py v2.2
# Movies: Radarr API (TMDB release date + path + size)
# TV:     Sonarr API (status = ended + lastAired date)
# Kids:   Never (excluded by root folder path)
#
# Read-only: produces a candidate JSON report consumed by
# cold_storage_cycle.sh. Nothing is moved or deleted here.
#
# Changes in v2.3:
#   - Protected franchise list moved to protected_franchises.txt
#     (PROTECTED_LIST_FILE); built-in list kept as fallback.
#   - Lock file prevents overlapping cron runs.
#   - Old logs pruned after LOG_RETENTION_DAYS (default 90).
#
# Changes in v2.2:
#   - Secrets/paths moved out of the source into environment
#     variables / config.env (see config.env.example).
#   - Refactored into functions so the decision rules are unit
#     testable. Behaviour is unchanged.
#
# Fixes in v2.1:
#   - Movie container paths now translated to host paths and
#     existence-checked (TV already did this; movies didn't).
#   - Candidates now include Radarr/Sonarr "id" so the cycle
#     script can unmonitor after a verified move. Without
#     this, Radarr WILL re-download archived monitored movies.
# ============================================================

import datetime
import fcntl
import json
import os
import urllib.error
import urllib.request

# --- KIDS-CONTENT HARD EXCLUSION (safety rail) ---------------
# Anything whose Radarr/Sonarr root folder starts with these
# container paths is NEVER a cold storage candidate, before any
# other rule is considered. Do not weaken these checks.
KIDS_MOVIE_ROOT = "/kids/"
KIDS_TV_ROOT = "/kidstv/"

# --- PROTECTED FRANCHISES ------------------------------------
# Substring match against the title (case-insensitive). These
# stay on the hot pool regardless of age/size.
# The canonical list lives in protected_franchises.txt (see
# PROTECTED_LIST_FILE); this built-in copy is the fallback when
# that file is missing.
PROTECTED = [
    "star wars", "rogue one", "solo", "andor",
    "star trek",
    "lord of the rings", "hobbit", "rohirrim",
    "avengers", "spider-man", "spider man", "iron man", "captain america",
    "thor", "black panther", "black widow", "doctor strange",
    "guardians of the galaxy", "ant-man", "deadpool", "x-men", "x men",
    "fantastic four", "eternals", "batman", "superman", "wonder woman",
    "aquaman", "justice league", "birds of prey", "dark knight", "joker",
    "shazam", "flash", "halloween", "nightmare on elm street",
    "friday the 13th", "saw", "chucky", "child's play", "childs play",
    "scream", "conjuring", "annabelle", "terrifier", "sinister", "insidious",
    "alien", "predator", "terminator", "matrix", "planet of the apes",
    "godzilla", "kong", "jurassic", "transformers", "pacific rim",
    "blade runner", "robocop", "avatar", "serenity", "starship troopers",
    "independence day", "total recall", "james bond", "harry potter",
    "fantastic beasts", "jedi", "man of steel", "suicide squad", "watchmen",
    "schitt's creek", "the expanse", "handmaid", "the continental",
]

# --- CONFIG --------------------------------------------------
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

DEFAULTS = {
    "RADARR_URL": "http://localhost:7878",
    "RADARR_API_KEY": "",
    "SONARR_URL": "http://localhost:8989",
    "SONARR_API_KEY": "",
    "MOVIES_DIR": "/volume1/Movies",
    "TV_DIR": "/volume1/TV Shows",
    "MOVIE_CONTAINER_PREFIX": "/movies/",
    "TV_CONTAINER_PREFIX": "/tv/",
    "LOG_DIR": os.path.join(_SCRIPT_DIR, "..", "logs"),
    "CANDIDATE_FILE": os.path.join(_SCRIPT_DIR, "..", "cold_storage_candidates.json"),
    "MOVIE_MIN_SIZE_GB": "2",
    "MOVIE_MIN_AGE_DAYS": "365",
    "TV_MIN_AGE_DAYS": "365",
    "PROTECTED_LIST_FILE": os.path.join(_SCRIPT_DIR, "..", "protected_franchises.txt"),
    "LOG_RETENTION_DAYS": "90",
    "LOCK_DIR": "/tmp",
}


def parse_config_file(path):
    """Parse a simple KEY=VALUE config.env file (bash-compatible subset)."""
    values = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                values[key.strip()] = value
    except OSError:
        pass
    return values


def load_config(config_path=None, environ=None):
    """Merge defaults <- config.env <- environment variables."""
    environ = os.environ if environ is None else environ
    if config_path is None:
        config_path = environ.get(
            "NAS_MEDIA_CONFIG", os.path.join(_SCRIPT_DIR, "..", "config.env")
        )
    cfg = dict(DEFAULTS)
    if config_path and os.path.isfile(config_path):
        for key, value in parse_config_file(config_path).items():
            if key in cfg:
                cfg[key] = value
    for key in cfg:
        if key in environ:
            cfg[key] = environ[key]
    return cfg


def build_path_map(cfg):
    """Container path prefix -> host path prefix translations."""
    return {
        cfg["MOVIE_CONTAINER_PREFIX"]: cfg["MOVIES_DIR"].rstrip("/") + "/",
        cfg["TV_CONTAINER_PREFIX"]: cfg["TV_DIR"].rstrip("/") + "/",
    }


def log(msg):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}")


def load_protected(path):
    """Load the franchise list from a text file (one substring per
    line, # comments). Falls back to the built-in PROTECTED list
    when the file is missing or unreadable."""
    try:
        with open(path) as f:
            entries = [
                line.strip().lower()
                for line in f
                if line.strip() and not line.strip().startswith("#")
            ]
        return entries if entries else list(PROTECTED)
    except OSError:
        return list(PROTECTED)


def acquire_lock(lock_path):
    """Take an exclusive non-blocking lock; exit if another scan
    holds it. Returns the open file object (keep it referenced —
    the lock lives as long as the fd)."""
    fd = open(lock_path, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fd.close()
        raise SystemExit(
            f"ERROR: another cold_storage_scan.py is running (lock: {lock_path})"
        )
    return fd


def prune_old_logs(log_dir, retention_days, now=None):
    """Delete *.log files in log_dir older than retention_days.
    Returns the number of files removed."""
    if now is None:
        now = datetime.datetime.now().timestamp()
    cutoff = now - retention_days * 86400
    removed = 0
    try:
        entries = os.scandir(log_dir)
    except OSError:
        return 0
    with entries:
        for entry in entries:
            if entry.name.endswith(".log") and entry.is_file():
                try:
                    if entry.stat().st_mtime < cutoff:
                        os.unlink(entry.path)
                        removed += 1
                except OSError:
                    continue
    return removed


def is_protected(name, protected=None):
    protected = PROTECTED if protected is None else protected
    name_lower = name.lower()
    return any(p in name_lower for p in protected)


def human_size(b):
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if b < 1024:
            return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} PB"


def translate_path(raw_path, path_map):
    """Container path -> host path. Returns unchanged if no prefix matches."""
    for prefix, host in path_map.items():
        if raw_path.startswith(prefix):
            return host + raw_path[len(prefix):]
    return raw_path


def api_get(base_url, apikey, endpoint):
    url = f"{base_url}/api/v3/{endpoint}"
    req = urllib.request.Request(url, headers={"X-Api-Key": apikey})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read().decode())
    except urllib.error.URLError as e:
        log(f"ERROR: API call failed ({url}): {e}")
        return None


def parse_added(date_str, now=None):
    """Return age in days from a date string."""
    if not date_str:
        return 0
    try:
        dt = datetime.datetime.fromisoformat(date_str.replace("Z", "+00:00"))
        if now is None:
            now = datetime.datetime.now(datetime.timezone.utc)
        return (now - dt).days
    except Exception:
        return 0


def get_release_age_days(movie, now=None):
    """TMDB release date fallback chain, then release year, else age 0.

    Uses the release date rather than filesystem mtime: a bulk NAS
    migration rewrites every mtime, but the TMDB date never changes.
    """
    release_str = (
        movie.get("digitalRelease")
        or movie.get("physicalRelease")
        or movie.get("inCinemas")
    )
    if release_str:
        return parse_added(release_str, now)
    year = movie.get("year", 0)
    fallback = f"{year}-01-01T00:00:00Z" if year else ""
    return parse_added(fallback, now) if fallback else 0


def evaluate_movie(movie, cfg, path_map, now=None, path_exists=os.path.isdir, protected=None):
    """Classify one Radarr movie record.

    Returns (category, payload) where category is one of:
      "no_file", "kids", "protected", "size", "age", "not_found",
      "candidate". Only "candidate" payloads are dicts; the rest
      are human-readable skip reasons.
    """
    title = movie.get("title", "")
    movie_id = movie.get("id")
    raw_path = movie.get("path", "")
    has_file = movie.get("hasFile", False)
    size = movie.get("sizeOnDisk", 0)
    size_gb = size / (1024 ** 3)

    min_size_gb = float(cfg["MOVIE_MIN_SIZE_GB"])
    min_age_days = int(cfg["MOVIE_MIN_AGE_DAYS"])

    # v2.1 FIX: translate to host path like the TV branch does
    path = translate_path(raw_path, path_map)

    # Use TMDB release date (survives NAS migrations)
    age_days = get_release_age_days(movie, now)

    if not has_file:
        return "no_file", title

    # Hard-exclude kids root folder (check the RAW container path)
    if raw_path.startswith(KIDS_MOVIE_ROOT):
        return "kids", f"{title} (kids root - never cold storage)"

    if is_protected(title, protected):
        return "protected", title

    if size_gb < min_size_gb:
        return "size", f"{title} ({human_size(size)})"

    if age_days < min_age_days:
        return "age", f"{title} ({age_days}d since release)"

    # v2.1 FIX: existence check on host path (TV had this, movies didn't)
    if not path or not path_exists(path):
        return "not_found", f"{title} (path not found: {path})"

    return "candidate", {
        "type": "movie",
        "id": movie_id,        # v2.1: needed for unmonitor
        "path": path,          # host path
        "name": title,
        "size_bytes": size,
        "size_human": human_size(size),
        "age_days": age_days,
    }


def evaluate_series(show, cfg, path_map, now=None, path_exists=os.path.isdir, protected=None):
    """Classify one Sonarr series record.

    Returns (category, payload) where category is one of:
      "kids", "protected", "status", "age", "not_found", "candidate".
    """
    title = show.get("title", "")
    series_id = show.get("id")
    status = show.get("status", "").lower()
    raw_path = show.get("path", "")
    # Translate Sonarr container path to real NAS host path
    path = translate_path(raw_path, path_map)
    size = show.get("statistics", {}).get("sizeOnDisk", 0)
    file_count = show.get("statistics", {}).get("episodeFileCount", 0)
    last_aired = show.get("lastAired", "") or show.get("added", "")
    age_days = parse_added(last_aired, now)

    min_age_days = int(cfg["TV_MIN_AGE_DAYS"])

    # Hard-exclude kids TV root folder
    if raw_path.startswith(KIDS_TV_ROOT):
        return "kids", f"{title} (kids root - never cold storage)"

    if is_protected(title, protected):
        return "protected", title

    if status != "ended":
        return "status", f"{title} ({status})"

    # Skip shows tracked in Sonarr but never actually downloaded
    if size == 0 or file_count == 0:
        return "status", f"{title} (no files on disk - watchlist only)"

    if age_days < min_age_days:
        return "age", f"{title} ({age_days}d since last aired)"

    if not path or not path_exists(path):
        return "not_found", f"{title} (path not found: {path})"

    return "candidate", {
        "type": "tv",
        "id": series_id,       # v2.1: needed for unmonitor
        "path": path,
        "name": title,
        "sonarr_status": status,
        "size_bytes": size,
        "size_human": human_size(size),
        "age_days": age_days,
    }


def scan_movies(radarr_data, cfg, path_map, now=None, path_exists=os.path.isdir, protected=None):
    """Run every Radarr record through evaluate_movie, log candidates."""
    buckets = {
        "candidate": [], "kids": [], "protected": [], "size": [],
        "age": [], "no_file": [], "not_found": [],
    }
    for movie in radarr_data:
        category, payload = evaluate_movie(movie, cfg, path_map, now, path_exists, protected)
        buckets[category].append(payload)
        if category == "candidate":
            log(f"  CANDIDATE: {payload['name']}")
            log(f"             Size: {payload['size_human']}  |  Release age: {payload['age_days']}d")
    return buckets


def scan_series(sonarr_data, cfg, path_map, now=None, path_exists=os.path.isdir, protected=None):
    """Run every Sonarr record through evaluate_series, log candidates."""
    buckets = {
        "candidate": [], "kids": [], "protected": [], "status": [],
        "age": [], "not_found": [],
    }
    for show in sonarr_data:
        category, payload = evaluate_series(show, cfg, path_map, now, path_exists, protected)
        buckets[category].append(payload)
        if category == "candidate":
            log(f"  CANDIDATE: {payload['name']}")
            log(f"             Status: ended  |  Size: {payload['size_human']}  |  Last aired: {payload['age_days']}d ago")
    return buckets


def main():
    cfg = load_config()
    path_map = build_path_map(cfg)

    lock = acquire_lock(os.path.join(cfg["LOCK_DIR"], "nas_media_cold_storage_scan.lock"))

    os.makedirs(cfg["LOG_DIR"], exist_ok=True)
    pruned = prune_old_logs(cfg["LOG_DIR"], int(cfg["LOG_RETENTION_DAYS"]))
    if pruned:
        log(f"Pruned {pruned} log file(s) older than {cfg['LOG_RETENTION_DAYS']} days")

    protected = load_protected(cfg["PROTECTED_LIST_FILE"])

    log("=" * 60)
    log("  cold_storage_scan.py v2.3")
    log(f"  Movie rule: >{cfg['MOVIE_MIN_SIZE_GB']}GB AND >{cfg['MOVIE_MIN_AGE_DAYS']} days (TMDB release)")
    log(f"  TV rule:    Sonarr status=ended AND >{cfg['TV_MIN_AGE_DAYS']} days (lastAired)")
    log("  Kids:       Never (excluded by root folder path)")
    log("=" * 60)
    log("")

    # --- MOVIES via Radarr -----------------------------------
    log("--- Scanning Movies (via Radarr) ---")
    movie_candidates = []
    if not cfg["RADARR_API_KEY"]:
        log("ERROR: RADARR_API_KEY not configured (see config.env.example). Movie scan skipped.")
    else:
        radarr_data = api_get(cfg["RADARR_URL"], cfg["RADARR_API_KEY"], "movie")
        if radarr_data is None:
            log("ERROR: Could not reach Radarr. Movie scan skipped.")
        else:
            m = scan_movies(radarr_data, cfg, path_map, protected=protected)
            movie_candidates = m["candidate"]
            log("")
            log(f"  Movie candidates:           {len(m['candidate'])}")
            log(f"  Skipped (protected/kids):   {len(m['protected']) + len(m['kids'])}")
            log(f"  Skipped (no file/missing):  {len(m['no_file'])}")
            log(f"  Skipped (under {cfg['MOVIE_MIN_SIZE_GB']}GB):        {len(m['size'])}")
            log(f"  Skipped (under {cfg['MOVIE_MIN_AGE_DAYS']} days):      {len(m['age'])}")
            log(f"  Path missing / unknown:     {len(m['not_found'])}")
            log("")

    # --- TV via Sonarr ---------------------------------------
    log("--- Scanning TV Shows (via Sonarr) ---")
    tv_candidates = []
    if not cfg["SONARR_API_KEY"]:
        log("ERROR: SONARR_API_KEY not configured (see config.env.example). TV scan skipped.")
    else:
        sonarr_data = api_get(cfg["SONARR_URL"], cfg["SONARR_API_KEY"], "series")
        if sonarr_data is None:
            log("ERROR: Could not reach Sonarr. TV scan skipped.")
        else:
            t = scan_series(sonarr_data, cfg, path_map, protected=protected)
            tv_candidates = t["candidate"]
            log("")
            log(f"  TV candidates:            {len(t['candidate'])}")
            log(f"  Skipped (protected/kids): {len(t['protected']) + len(t['kids'])}")
            log(f"  Skipped (not ended/no files): {len(t['status'])}")
            log(f"  Skipped (under {cfg['TV_MIN_AGE_DAYS']} days):  {len(t['age'])}")
            log(f"  Path missing / unknown:   {len(t['not_found'])}")
            log("")

    # --- SUMMARY ---------------------------------------------
    all_candidates = movie_candidates + tv_candidates
    total_size = sum(c["size_bytes"] for c in all_candidates)

    log("=" * 60)
    log("  SUMMARY")
    log(f"  Movie candidates: {len(movie_candidates)}")
    log(f"  TV candidates:    {len(tv_candidates)}")
    log(f"  Total candidates: {len(all_candidates)}")
    log(f"  Total size:       {human_size(total_size)}")
    log(f"  Candidate file:   {cfg['CANDIDATE_FILE']}")
    log("=" * 60)

    output = {
        "generated": datetime.datetime.now().isoformat(),
        "total_candidates": len(all_candidates),
        "total_size_bytes": total_size,
        "total_size_human": human_size(total_size),
        "candidates": all_candidates,
    }

    with open(cfg["CANDIDATE_FILE"], "w") as f:
        json.dump(output, f, indent=2)

    log(f"Candidate list written to {cfg['CANDIDATE_FILE']}")
    lock.close()


if __name__ == "__main__":
    main()
