#!/bin/bash
# ============================================================
# secret_scan.sh
# Deterministic, dependency-free secret scan for CI and local
# use. Fails (exit 1) if any tracked file looks like it contains
# a real credential. Intentionally conservative to avoid false
# positives - it is a safety net, not a replacement for a full
# entropy scanner (see the tracked follow-up to add gitleaks).
#
# Checks tracked files (git ls-files) for:
#   1. The two API keys that shipped in the ORIGINAL unsanitized
#      scripts - a regression tripwire in case they ever return.
#   2. A 32-char lowercase-hex string (the Radarr/Sonarr API-key
#      shape) in any shell/python source - placeholders use
#      <ANGLE_BRACKETS>, so a bare hex key means a real leak.
#   3. A hardcoded RFC1918 NAS IP in source (config uses <NAS_IP>).
#
# Usage: bash tests/secret_scan.sh
# ============================================================
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 2

FAILURES=0

report() { # report <description> <grep-output>
    echo "  LEAK: $1"
    printf '        %s\n' "$2"
    ((FAILURES++))
}

# The file list: tracked files if in a git repo, else everything
# (minus the usual noise) so the scan also works from a tarball.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mapfile -t _ALL < <(git ls-files)
else
    mapfile -t _ALL < <(find . -type f \
        -not -path './.git/*' -not -path './logs/*' \
        -not -path '*/__pycache__/*' -not -path '*/.pytest_cache/*')
fi

# Exclude this scanner from its own scan: it legitimately contains the
# known-key detection pattern, which would otherwise self-match.
FILES=()
for _f in "${_ALL[@]}"; do
    case "$_f" in
        *secret_scan.sh) continue ;;
    esac
    FILES+=("$_f")
done

# 1. Known-leaked keys from the original scripts (exact match)
KNOWN='d69990213cc84c2cacfd296337497283|d522a749cff641dcbff868ed34de5465'
if OUT=$(grep -REn "$KNOWN" "${FILES[@]}" 2>/dev/null); then
    report "known original API key present" "$OUT"
fi

# 2. arr-key-shaped 32-hex in source (placeholders are <...>, and
#    tests use short low-entropy fakes like 'abc123')
SRC=()
for f in "${FILES[@]}"; do
    case "$f" in
        *.sh|*.py) SRC+=("$f") ;;
    esac
done
if [[ ${#SRC[@]} -gt 0 ]]; then
    if OUT=$(grep -REn '\b[0-9a-f]{32}\b' "${SRC[@]}" 2>/dev/null); then
        report "32-char hex string (looks like a real API key)" "$OUT"
    fi
fi

# 3. Hardcoded private NAS IP in source (config template uses <NAS_IP>)
if [[ ${#SRC[@]} -gt 0 ]]; then
    if OUT=$(grep -REn '\b(192\.168|10\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]+\.[0-9]+' "${SRC[@]}" 2>/dev/null); then
        report "hardcoded RFC1918 IP in source" "$OUT"
    fi
fi

if (( FAILURES > 0 )); then
    echo "secret_scan: $FAILURES potential leak(s) found."
    exit 1
fi
echo "secret_scan: clean."
