#!/usr/bin/env python3
# ============================================================
# torrent_cleanup_api.py v1
# The qBittorrent-API successor to torrent_cleanup.sh.
#
# torrent_cleanup.sh deletes payload files straight off the
# disk. If qBittorrent still has the torrent loaded that breaks
# the seed (missing-file errors, H&R risk on private trackers).
# This version asks qBittorrent to remove the torrent AND its
# data via the Web API, so the client's state always matches
# the disk - and it can check actual seeding state instead of
# guessing.
#
# A torrent is deleted only when ALL of these hold:
#   1. Download is complete (progress == 1.0).
#   2. Seeding goal met: ratio >= QBT_MIN_RATIO  OR
#      seeding time >= QBT_MIN_SEED_DAYS.
#   3. A matching folder exists in the media library
#      (i.e. the import is confirmed).
# Everything else is reported and left alone.
#
# Usage:
#   python3 torrent_cleanup_api.py          <- dry run (default)
#   python3 torrent_cleanup_api.py --run    <- live removal
# ============================================================

import datetime
import fcntl
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

DEFAULTS = {
    "QBT_URL": "http://localhost:8080",
    "QBT_USERNAME": "",
    "QBT_PASSWORD": "",
    "QBT_MIN_RATIO": "1.0",
    "QBT_MIN_SEED_DAYS": "7",
    "MOVIES_DIR": "/volume1/Movies",
    "TV_DIR": "/volume1/TV Shows",
    "LOG_DIR": os.path.join(_SCRIPT_DIR, "..", "logs"),
    "LOCK_DIR": "/tmp",
    "NTFY_URL": "",
    "DISCORD_WEBHOOK_URL": "",
}

# Quality/codec tags - everything from the first tag onwards is
# stripped (same list the shell scripts use)
_TAGS = (
    "2160p|1080p|1080i|720p|480p|4k|uhd|hdr10\\+|hdr10|hdr|dv|bluray|blu-ray|"
    "bdrip|brrip|web-dl|webdl|webrip|web|hdtv|dvdrip|xvid|x264|x265|h264|h265|"
    "hevc|avc|aac|ac3|dts|truehd|atmos|remux|proper|repack|extended|theatrical|"
    "directors|unrated|remastered|amzn|nf|max|dsnp|hulu|peacock|multi|german|"
    "french|spanish|italian|dl|subs|subbed|dubbed|10bit|8bit"
)


def log(msg):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}")


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


def notify(cfg, message):
    """Best-effort push notification; failures never break a run."""
    ntfy = cfg.get("NTFY_URL", "")
    if ntfy:
        try:
            req = urllib.request.Request(
                ntfy, data=message.encode(), headers={"Title": "torrent_cleanup_api"}
            )
            with urllib.request.urlopen(req, timeout=10):
                pass
        except Exception as e:
            log(f"WARNING: ntfy notification failed: {e}")
    discord = cfg.get("DISCORD_WEBHOOK_URL", "")
    if discord:
        try:
            req = urllib.request.Request(
                discord,
                data=json.dumps({"content": message}).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=10):
                pass
        except Exception as e:
            log(f"WARNING: discord notification failed: {e}")


def acquire_lock(lock_path):
    fd = open(lock_path, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fd.close()
        raise SystemExit(
            f"ERROR: another torrent_cleanup_api.py is running (lock: {lock_path})"
        )
    return fd


def normalize(name):
    """Python port of the shell scripts' normalize(): reduce a
    release name to a bare title for matching against library
    folder names. Kept in lockstep with torrent_cleanup.sh."""
    s = name.rsplit(".", 1)[0] if "." in name else name
    s = s.lower()
    s = s.replace(" - ", " ")
    s = s.replace(".", " ").replace("_", " ")
    s = re.sub(r"s[0-9]{1,2}e[0-9]{1,2}.*", "", s)          # SxxExx episodes
    s = re.sub(r"\bs[0-9]{1,2}\b.*", "", s)                 # bare season packs
    s = re.sub(r"[0-9]{4} [0-9]{2} [0-9]{2}.*", "", s)      # dated episodes
    s = re.sub(rf"\b({_TAGS})\b.*", "", s)                  # quality tags onward
    s = re.sub(r"\[[^\]]*\]", "", s)
    s = re.sub(r"\([^)]*\)", "", s)
    s = re.sub(r"\b(19|20)[0-9]{2}\b", "", s)               # years
    s = re.sub(r"-[a-zA-Z0-9]+$", "", s)                    # -GROUP suffix
    s = re.sub(r" +", " ", s).strip()
    return s


def build_library_index(*dirs):
    """Map of normalized folder name -> actual folder name across
    the given library directories."""
    index = {}
    for d in dirs:
        try:
            entries = os.scandir(d)
        except OSError:
            continue
        with entries:
            for entry in entries:
                if entry.is_dir():
                    norm = normalize(entry.name)
                    if norm:
                        index[norm] = entry.name
    return index


def classify_torrent(torrent, library_index, min_ratio, min_seed_secs):
    """Decide what to do with one qBittorrent torrent record.

    Returns (category, reason) with category one of:
      "downloading" - incomplete, never touched
      "seeding"     - complete but goal not met, never touched
      "unmatched"   - goal met but no library match, kept
      "removable"   - complete + goal met + confirmed imported
    """
    name = torrent.get("name", "")
    progress = torrent.get("progress", 0)
    ratio = torrent.get("ratio", 0)
    seeding_time = torrent.get("seeding_time", 0)

    if progress < 1.0:
        return "downloading", f"{name} ({progress * 100:.0f}% complete)"

    if ratio < min_ratio and seeding_time < min_seed_secs:
        return "seeding", (
            f"{name} (ratio {ratio:.2f} < {min_ratio:.2f}, "
            f"seeded {seeding_time // 86400}d < {min_seed_secs // 86400}d)"
        )

    matched = library_index.get(normalize(name))
    if not matched:
        return "unmatched", f"{name} (no library match)"

    return "removable", f"{name} (matched: {matched})"


class QbtClient:
    """Thin qBittorrent Web API v2 client (urllib only)."""

    def __init__(self, base_url, timeout=15):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.cookie = ""

    def _request(self, endpoint, data=None):
        url = f"{self.base_url}/api/v2/{endpoint}"
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        headers = {"Referer": self.base_url}
        if self.cookie:
            headers["Cookie"] = self.cookie
        req = urllib.request.Request(url, data=body, headers=headers)
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            set_cookie = r.headers.get("Set-Cookie", "")
            if set_cookie.startswith("SID="):
                self.cookie = set_cookie.split(";", 1)[0]
            return r.read().decode()

    def login(self, username, password):
        """Returns True on success. qBittorrent replies 'Ok.' on
        success and 'Fails.' on bad credentials (both HTTP 200)."""
        try:
            resp = self._request(
                "auth/login", {"username": username, "password": password}
            )
        except (urllib.error.URLError, OSError) as e:
            log(f"ERROR: cannot reach qBittorrent at {self.base_url}: {e}")
            return False
        if resp.strip() != "Ok.":
            log("ERROR: qBittorrent login failed (check QBT_USERNAME/QBT_PASSWORD)")
            return False
        return True

    def torrents_info(self):
        try:
            return json.loads(self._request("torrents/info"))
        except (urllib.error.URLError, OSError, ValueError) as e:
            log(f"ERROR: could not list torrents: {e}")
            return None

    def delete(self, torrent_hash, delete_files=True):
        """Remove a torrent and (by default) its data - the whole
        point of using the API instead of rm."""
        try:
            self._request(
                "torrents/delete",
                {
                    "hashes": torrent_hash,
                    "deleteFiles": "true" if delete_files else "false",
                },
            )
            return True
        except (urllib.error.URLError, OSError) as e:
            log(f"ERROR: delete failed for {torrent_hash}: {e}")
            return False


def main():
    cfg = load_config()
    dry_run = "--run" not in sys.argv[1:]

    lock = acquire_lock(
        os.path.join(cfg["LOCK_DIR"], "nas_media_torrent_cleanup.lock")
    )

    os.makedirs(cfg["LOG_DIR"], exist_ok=True)

    min_ratio = float(cfg["QBT_MIN_RATIO"])
    min_seed_secs = int(float(cfg["QBT_MIN_SEED_DAYS"]) * 86400)

    log("=" * 60)
    log("  torrent_cleanup_api.py v1")
    log(f"  DRY_RUN: {dry_run}")
    log(f"  qBittorrent: {cfg['QBT_URL']}")
    log(f"  Removal rule: complete AND (ratio >= {min_ratio}")
    log(f"                OR seeded >= {cfg['QBT_MIN_SEED_DAYS']}d) AND imported")
    log("=" * 60)
    log("")

    library_index = build_library_index(cfg["MOVIES_DIR"], cfg["TV_DIR"])
    log(f"Library folders indexed: {len(library_index)}")

    client = QbtClient(cfg["QBT_URL"])
    if not client.login(cfg["QBT_USERNAME"], cfg["QBT_PASSWORD"]):
        notify(cfg, "torrent_cleanup_api ERROR: qBittorrent login failed")
        raise SystemExit(1)

    torrents = client.torrents_info()
    if torrents is None:
        notify(cfg, "torrent_cleanup_api ERROR: could not list torrents")
        raise SystemExit(1)
    log(f"Torrents in client: {len(torrents)}")
    log("")

    counts = {"downloading": 0, "seeding": 0, "unmatched": 0, "removable": 0}
    removed = 0
    freed = 0

    for torrent in sorted(torrents, key=lambda t: t.get("name", "")):
        category, reason = classify_torrent(
            torrent, library_index, min_ratio, min_seed_secs
        )
        counts[category] += 1
        log(f"  [{category.upper():11}] {reason}")

        if category != "removable":
            continue

        size = torrent.get("size", 0)
        if dry_run:
            log("               [DRY RUN] would remove torrent + data")
            removed += 1
            freed += size
        else:
            if client.delete(torrent.get("hash", ""), delete_files=True):
                log("               REMOVED torrent + data via API")
                removed += 1
                freed += size
            else:
                log("               ERROR - removal failed, torrent kept")

    freed_gb = freed / (1024 ** 3)
    log("")
    log("=" * 60)
    log("  SUMMARY")
    log(f"  Downloading (kept):   {counts['downloading']}")
    log(f"  Still seeding (kept): {counts['seeding']}")
    log(f"  Unmatched (kept):     {counts['unmatched']}")
    if dry_run:
        log(f"  Would remove:         {removed} (~{freed_gb:.2f} GB)")
        log("  Run with --run to execute")
        notify(
            cfg,
            f"torrent_cleanup_api DRY RUN: {removed} torrent(s) removable (~{freed_gb:.2f} GB)",
        )
    else:
        log(f"  Removed:              {removed} (~{freed_gb:.2f} GB freed)")
        notify(
            cfg,
            f"torrent_cleanup_api: removed {removed} torrent(s) (~{freed_gb:.2f} GB freed)",
        )
    log("=" * 60)
    lock.close()


if __name__ == "__main__":
    main()
