#!/bin/bash
# ============================================================
# install.sh
# Installer + health check ("doctor") for nas-media-automation.
#
# Usage:
#   bash install.sh                 <- install in place (this checkout)
#   bash install.sh --dir /volume1/docker/scripts/nas-media-automation
#                                   <- copy the tooling to another directory
#   bash install.sh --yes           <- non-interactive: no prompts, keep
#                                      config placeholders for later editing
#   bash install.sh --doctor        <- change nothing; verify an existing
#                                      install (prereqs, config, paths,
#                                      Radarr/Sonarr/Tautulli connectivity)
#
# What install does:
#   1. Checks prerequisites (bash 4+, python3 3.8+, rsync, flock).
#   2. Copies the tooling to --dir (or sets up this checkout in place).
#   3. Creates config.env from config.env.example - NEVER overwrites
#      an existing config.env - and locks it down to mode 600.
#   4. Interactively prompts for the core settings (skip with --yes).
#   5. Syntax-verifies every script, then runs the doctor checks.
#
# Nothing here touches your media. Every installed script still
# defaults to dry-run and requires --run for destructive actions.
# ============================================================
# shellcheck disable=SC2030,SC2031  # doctor() intentionally runs in a
# subshell (sourcing the user's config must not leak into the installer);
# its WARNINGS/FAILURES counters flow back via run_doctor's stats file.
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$REPO_DIR"
ASSUME_YES=false
DOCTOR_ONLY=false

usage() {
    sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --dir needs a path" >&2
                exit 1
            fi
            INSTALL_DIR="$2"; shift 2 ;;
        --yes|-y)  ASSUME_YES=true; shift ;;
        --doctor)  DOCTOR_ONLY=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: unknown option '$1'" >&2; usage; exit 1 ;;
    esac
done

CONFIG_PATH="$INSTALL_DIR/config.env"
WARNINGS=0
FAILURES=0

say()  { printf '%s\n' "$1"; }
ok()   { printf '  [ OK ] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; ((WARNINGS++)); }
fail() { printf '  [FAIL] %s\n' "$1"; ((FAILURES++)); }

# A value straight from config.env.example still contains <PLACEHOLDERS>
is_placeholder() {
    [[ -z "$1" || "$1" == *"<"* ]]
}

# --- 1. PREREQUISITES ----------------------------------------
check_prereqs() {
    say ""
    say "=== Prerequisites ==="
    if (( BASH_VERSINFO[0] >= 4 )); then
        ok "bash ${BASH_VERSION%%(*}"
    else
        fail "bash 4+ required (found ${BASH_VERSION%%(*})"
    fi

    if command -v python3 >/dev/null 2>&1; then
        if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'; then
            ok "python3 $(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
        else
            fail "python3 3.8+ required (found $(python3 --version 2>&1))"
        fi
    else
        fail "python3 not found"
    fi

    for tool in rsync flock; do
        if command -v "$tool" >/dev/null 2>&1; then
            ok "$tool"
        else
            fail "$tool not found (on Synology: install via Package Center or opkg)"
        fi
    done

    if command -v curl >/dev/null 2>&1; then
        ok "curl"
    else
        warn "curl not found - push notifications (NTFY_URL/DISCORD_WEBHOOK_URL) won't work"
    fi
}

# --- 2. COPY / IN-PLACE SETUP --------------------------------
install_files() {
    say ""
    say "=== Install ==="
    if [[ "$INSTALL_DIR" != "$REPO_DIR" ]]; then
        mkdir -p "$INSTALL_DIR" || { fail "cannot create $INSTALL_DIR"; return; }
        if cp -R "$REPO_DIR/scripts" "$INSTALL_DIR/" \
            && cp "$REPO_DIR/protected_franchises.txt" \
                  "$REPO_DIR/config.env.example" \
                  "$REPO_DIR/install.sh" \
                  "$REPO_DIR/README.md" \
                  "$REPO_DIR/LICENSE" "$INSTALL_DIR/" \
            && cp -R "$REPO_DIR/docs" "$INSTALL_DIR/"; then
            ok "tooling copied to $INSTALL_DIR"
        else
            fail "copy to $INSTALL_DIR failed"
            return
        fi
    else
        ok "installing in place ($INSTALL_DIR)"
    fi

    chmod +x "$INSTALL_DIR/scripts/"*.sh "$INSTALL_DIR/scripts/"*.py
    ok "scripts marked executable"
}

# --- 3. CONFIG -----------------------------------------------
create_config() {
    say ""
    say "=== Configuration ==="
    if [[ -f "$CONFIG_PATH" ]]; then
        ok "existing config.env kept (never overwritten)"
        CONFIG_IS_FRESH=false
    else
        cp "$INSTALL_DIR/config.env.example" "$CONFIG_PATH" \
            || { fail "could not create $CONFIG_PATH"; return; }
        chmod 600 "$CONFIG_PATH"
        ok "config.env created from template (mode 600 - it will hold API keys)"
        CONFIG_IS_FRESH=true
    fi
}

# set_config_value KEY VALUE - rewrite one assignment in config.env,
# preserving all comments. config.env is later `source`d by bash, so
# the value is shell-escaped for a double-quoted context (\ " $ `);
# an unescaped " or $ would otherwise corrupt the file or, worse,
# execute on the next run.
set_config_value() {
    python3 - "$CONFIG_PATH" "$1" "$2" <<'PYEOF'
import re, sys
path, key, value = sys.argv[1:4]
with open(path) as f:
    text = f.read()
esc = (value.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("$", "\\$")
            .replace("`", "\\`"))
line = f'{key}="{esc}"'
pattern = re.compile(rf'^#?\s*{re.escape(key)}=.*$', re.M)
if pattern.search(text):
    # function replacement: no backslash-escape processing on `line`
    text = pattern.sub(lambda _m: line, text, count=1)
else:
    text = text.rstrip("\n") + "\n" + line + "\n"
with open(path, "w") as f:
    f.write(text)
PYEOF
}

prompt_config_values() {
    # Only for a freshly created config, only on a real terminal,
    # and only unless --yes asked us not to.
    if [[ "$CONFIG_IS_FRESH" != true || "$ASSUME_YES" == true || ! -t 0 ]]; then
        if [[ "$CONFIG_IS_FRESH" == true ]]; then
            say "  Skipping guided setup - edit $CONFIG_PATH before first use."
        fi
        return
    fi

    say ""
    say "  Guided setup - press Enter to keep the value shown in [brackets]."
    say ""

    local key desc default value
    while IFS='|' read -r key desc default; do
        printf '  %s\n' "$desc"
        read -r -p "  $key [$default]: " value </dev/tty
        value="${value:-$default}"
        set_config_value "$key" "$value"
    done <<'FIELDS'
MOVIES_DIR|Host path of your movie library|/volume1/Movies
TV_DIR|Host path of your TV library|/volume1/TV Shows
COLD_ROOT|Cold storage (USB archive) mount + subfolder. Find yours with:  df -h | grep -i usb   (Synology is often /mnt/@usb/sdX1/Cold or /volumeUSB1/usbshare/Cold). Leave blank to set later.|
RADARR_URL|Radarr URL (Settings > General shows the port)|http://localhost:7878
RADARR_API_KEY|Radarr API key (Settings > General > Security)|
SONARR_URL|Sonarr URL|http://localhost:8989
SONARR_API_KEY|Sonarr API key (Settings > General > Security)|
FIELDS
    say ""
    ok "core settings written to config.env"
    say "  Optional extras (Tautulli guard, notifications, qBittorrent API,"
    say "  capacity target) are documented inline in config.env."
}

# --- 4. VERIFY THE INSTALLED SCRIPTS -------------------------
verify_scripts() {
    say ""
    say "=== Script verification ==="
    local f rc=0
    for f in "$INSTALL_DIR/scripts/"*.sh; do
        if bash -n "$f" 2>/dev/null; then
            ok "bash -n $(basename "$f")"
        else
            fail "syntax error in $(basename "$f")"
            rc=1
        fi
    done
    for f in "$INSTALL_DIR/scripts/"*.py; do
        if python3 -m py_compile "$f" 2>/dev/null; then
            ok "py_compile $(basename "$f")"
        else
            fail "compile error in $(basename "$f")"
            rc=1
        fi
    done
    return $rc
}

# arr_reachable URL KEY - 0 when the v3 API answers with this key.
# Key travels via the environment, not argv (argv is world-readable
# through /proc/<pid>/cmdline; environ is owner/root-only).
arr_reachable() {
    NAS_ARR_KEY="$2" python3 - "$1" <<'PYEOF'
import os, sys, urllib.request
url, key = sys.argv[1].rstrip("/"), os.environ["NAS_ARR_KEY"]
req = urllib.request.Request(f"{url}/api/v3/system/status", headers={"X-Api-Key": key})
try:
    with urllib.request.urlopen(req, timeout=5) as r:
        sys.exit(0 if r.status == 200 else 1)
except Exception:
    sys.exit(1)
PYEOF
}

tautulli_reachable() {
    NAS_ARR_KEY="$2" python3 - "$1" <<'PYEOF'
import json, os, sys, urllib.parse, urllib.request
url, key = sys.argv[1].rstrip("/"), os.environ["NAS_ARR_KEY"]
q = urllib.parse.urlencode({"apikey": key, "cmd": "status"})
try:
    with urllib.request.urlopen(f"{url}/api/v2?{q}", timeout=5) as r:
        body = json.loads(r.read().decode())
    sys.exit(0 if body.get("response", {}).get("result") == "success" else 1)
except Exception:
    sys.exit(1)
PYEOF
}

# --- 5. DOCTOR -----------------------------------------------
# Runs in a subshell so sourcing the user's config can't leak
# into the installer itself; counters flow back via a stats file.
DOCTOR_STATS_FILE=""

_doctor_done() {
    echo "$WARNINGS $FAILURES" > "$DOCTOR_STATS_FILE"
    exit "$1"
}

run_doctor() {
    DOCTOR_STATS_FILE=$(mktemp)
    doctor
    local rc=$? dw df
    if [[ -s "$DOCTOR_STATS_FILE" ]]; then
        read -r dw df < "$DOCTOR_STATS_FILE"
        (( WARNINGS += dw ))
        (( FAILURES += df ))
    fi
    rm -f "$DOCTOR_STATS_FILE"
    return $rc
}

doctor() (
    WARNINGS=0
    FAILURES=0
    say ""
    say "=== Doctor ==="
    if [[ ! -f "$CONFIG_PATH" ]]; then
        fail "config.env not found at $CONFIG_PATH - run install first"
        _doctor_done 1
    fi
    ok "config.env present"

    # config.env holds API keys and is sourced (executed). Writable by
    # group/other means code injection: REFUSE, matching the scripts.
    # Readable by group/other merely leaks keys: warn.
    _cfg_perm=$(stat -c '%a' "$CONFIG_PATH" 2>/dev/null || echo "")
    if [[ -n "$_cfg_perm" && $(( 8#$_cfg_perm & 022 )) -ne 0 ]]; then
        fail "config.env is group/other-WRITABLE (mode $_cfg_perm) - refusing to source it. Fix: chmod 600 $CONFIG_PATH"
        _doctor_done 1
    elif [[ -n "$_cfg_perm" && $(( 8#$_cfg_perm & 044 )) -ne 0 ]]; then
        warn "config.env mode is $_cfg_perm (group/other can READ it - it holds API keys). Fix: chmod 600 $CONFIG_PATH"
    else
        ok "config.env permissions locked down (mode ${_cfg_perm:-unknown})"
    fi

    set +u
    # shellcheck disable=SC1090  # the user's own config
    source "$CONFIG_PATH"

    local d
    for d in "MOVIES_DIR:${MOVIES_DIR:-}" "TV_DIR:${TV_DIR:-}"; do
        local name="${d%%:*}" path="${d#*:}"
        if is_placeholder "$path"; then
            warn "$name not configured yet"
        elif [[ -d "$path" ]]; then
            ok "$name exists ($path)"
        else
            warn "$name does not exist: $path"
        fi
    done

    if is_placeholder "${COLD_ROOT:-}"; then
        warn "COLD_ROOT not configured yet (needed for cold storage cycle/restore)"
    elif [[ -d "${COLD_ROOT}" ]]; then
        ok "COLD_ROOT mounted ($COLD_ROOT)"
    else
        warn "COLD_ROOT does not exist: $COLD_ROOT"
        say "         cold_storage_cycle.sh and restore will refuse to run until this"
        say "         path exists. Plug in the archive drive, then find its real mount:"
        say "           df -h | grep -i usb"
        say "         On Synology it is usually /mnt/@usb/sdX1/... or /volumeUSB1/usbshare/..."
        say "         Set COLD_ROOT in $CONFIG_PATH to that path + a /Cold subfolder."
    fi

    if is_placeholder "${RADARR_API_KEY:-}" || is_placeholder "${RADARR_URL:-}"; then
        warn "Radarr not configured yet (movie scan will be skipped)"
    elif arr_reachable "$RADARR_URL" "$RADARR_API_KEY"; then
        ok "Radarr reachable ($RADARR_URL)"
    else
        warn "Radarr NOT reachable at $RADARR_URL (check URL/API key/firewall)"
    fi

    if is_placeholder "${SONARR_API_KEY:-}" || is_placeholder "${SONARR_URL:-}"; then
        warn "Sonarr not configured yet (TV scan will be skipped)"
    elif arr_reachable "$SONARR_URL" "$SONARR_API_KEY"; then
        ok "Sonarr reachable ($SONARR_URL)"
    else
        warn "Sonarr NOT reachable at $SONARR_URL (check URL/API key/firewall)"
    fi

    if ! is_placeholder "${TAUTULLI_URL:-}" && ! is_placeholder "${TAUTULLI_API_KEY:-}"; then
        if tautulli_reachable "$TAUTULLI_URL" "$TAUTULLI_API_KEY"; then
            ok "Tautulli reachable ($TAUTULLI_URL) - watched guard active"
        else
            warn "Tautulli NOT reachable at $TAUTULLI_URL (watched guard will be skipped)"
        fi
    fi

    _doctor_done 0
)

next_steps() {
    say ""
    say "=== Next steps ==="
    say "  1. Review your settings:      vi $CONFIG_PATH"
    say "  2. Re-check the install:      bash $INSTALL_DIR/install.sh --doctor"
    say "  3. Try everything in dry-run (nothing is deleted or moved):"
    say "       bash $INSTALL_DIR/scripts/duplicate_cleanup.sh"
    say "       python3 $INSTALL_DIR/scripts/cold_storage_scan.py"
    say "       bash $INSTALL_DIR/scripts/cold_storage_cycle.sh"
    say "  4. Schedule the read-only scan (weekly, Sunday 03:00):"
    say "       0 3 * * 0  python3 $INSTALL_DIR/scripts/cold_storage_scan.py"
    say "     On Synology DSM use Control Panel > Task Scheduler"
    say "     (a user-defined script task) rather than editing crontab -"
    say "     DSM can overwrite /etc/crontab on updates."
    say "  5. Destructive steps stay manual: add --run only after you have"
    say "     read a dry-run report and agree with every line of it."
}

# --- MAIN ----------------------------------------------------
# Guarded so the file can be `source`d (e.g. by tests) to reuse the
# functions above without running the installer.
main() {
    say "nas-media-automation installer"
    say "=============================="

    if [[ "$DOCTOR_ONLY" == true ]]; then
        check_prereqs
        run_doctor || true
    else
        check_prereqs
        if (( FAILURES > 0 )); then
            say ""
            say "ERROR: fix the failed prerequisites above, then re-run install.sh"
            exit 1
        fi
        CONFIG_IS_FRESH=false
        install_files
        create_config
        prompt_config_values
        verify_scripts
        run_doctor || true
        next_steps
    fi

    say ""
    if (( FAILURES > 0 )); then
        say "Finished with $FAILURES failure(s) and $WARNINGS warning(s)."
        exit 1
    fi
    say "Finished with $WARNINGS warning(s). Warnings are normal until config.env is filled in."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
