#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# install-latest.sh
#
# Resolve and download the latest released tarball of aidlc-ops. Always
# fetches the most recent tagged release via the GitHub Releases API, so
# the user never has to know the current version number to get the
# bleeding-edge of releases.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rap77/aidlc-ops/main/scripts/install-latest.sh \
#     | bash
#
#   curl ... | bash -s -- /opt/aidlc-ops    # custom target dir (default: ~/.aidlc-ops)
#   curl ... | bash -s -- --user other-user  # use a different GitHub user/org
#   curl ... | bash -s -- --verify           # require a valid sha256 (default: best-effort)
#
# Exit codes:
#   0  Downloaded and extracted successfully.
#   1  Network / API error.
#   2  Invalid arguments.
#   3  Required tool missing (curl, tar).
# ----------------------------------------------------------------------------
set -euo pipefail

REPO_OWNER="rap77"
REPO_NAME="aidlc-ops"
TARGET_DIR="$HOME/.aidlc-ops"
REQUIRE_VERIFY=0

# ---- arg parsing -----------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) REPO_OWNER="${2:?--user requires a GitHub user/org}"; shift 2 ;;
        --verify) REQUIRE_VERIFY=1; shift ;;
        -h|--help)
            cat <<'USAGE'
Usage: curl ... | bash -s -- [TARGET_DIR] [--user NAME] [--verify]

Resolves the latest tagged release of aidlc-ops via the GitHub API and
extracts it into TARGET_DIR (default: ~/.aidlc-ops).

Flags:
  --user NAME   Use a GitHub user/org other than the default (rap77).
  --verify      Require a valid sha256 (default: best-effort, warn if missing).
USAGE
            exit 0
            ;;
        -*)
            echo "error: unknown flag '$1'" >&2; exit 2 ;;
        *)
            TARGET_DIR="$1"; shift ;;
    esac
done

# ---- preconditions ---------------------------------------------------------

for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: '$tool' not on PATH — install it first" >&2
        exit 3
    }
done

# ---- resolve latest release -------------------------------------------------

API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
echo "→ resolving latest release from $API_URL"

# Follow redirects (the API itself never redirects, but be safe).
release_json="$(curl -fsSL "$API_URL")" || {
    echo "error: GitHub API call failed (rate limit? network? typo on --user?)" >&2
    exit 1
}

# Extract fields with grep -E + sed (no jq dependency).
tag_name=$(echo "$release_json" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
tarball_url=$(echo "$release_json" | grep -oE '"tarball_url"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')

if [[ -z "$tag_name" || -z "$tarball_url" ]]; then
    echo "error: could not parse tag_name or tarball_url from API response" >&2
    exit 1
fi

# Find the asset named aidlc-ops-<tag>.tar.gz and its .sha256 sibling.
# The GitHub API returns assets[].browser_download_url for direct downloads,
# which is more reliable than tarball_url (the source tarball, not the kit).
assets_json=$(echo "$release_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for a in d.get('assets', []):
    print(a['name'])
    print(a['browser_download_url'])
" 2>/dev/null || echo "")

kit_url=""
sha_url=""
if [[ -n "$assets_json" ]]; then
    while IFS= read -r name; read -r url; do
        case "$name" in
            aidlc-ops-*.tar.gz.sha256) sha_url="$url" ;;
            aidlc-ops-*.tar.gz)         kit_url="$url" ;;
        esac
    done <<< "$assets_json"
fi

# Fallback to the source tarball if the kit asset is missing (older releases).
if [[ -z "$kit_url" ]]; then
    kit_url="$tarball_url"
fi

echo "  tag:    $tag_name"
echo "  kit:    $kit_url"
[[ -n "$sha_url" ]] && echo "  sha256: $sha_url"

# ---- download ---------------------------------------------------------------

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "→ downloading"
curl -fsSL -o "$tmp/kit.tar.gz" "$kit_url" || {
    echo "error: tarball download failed" >&2
    exit 1
}

# ---- verify (best-effort unless --verify) ----------------------------------

if [[ -n "$sha_url" ]]; then
    curl -fsSL -o "$tmp/kit.tar.gz.sha256" "$sha_url"
    expected=$(awk '{print $1}' "$tmp/kit.tar.gz.sha256")
    actual=$(sha256sum "$tmp/kit.tar.gz" | awk '{print $1}')
    if [[ "$expected" == "$actual" ]]; then
        echo "  sha256 OK"
    else
        echo "error: sha256 mismatch (expected $expected, got $actual)" >&2
        exit 1
    fi
else
    if [[ $REQUIRE_VERIFY -eq 1 ]]; then
        echo "error: --verify requested but no .sha256 asset found for $tag_name" >&2
        exit 1
    fi
    echo "  sha256: not available for this release (skipped)"
fi

# ---- extract ---------------------------------------------------------------

echo "→ extracting into $TARGET_DIR"
mkdir -p "$TARGET_DIR"
tar -xzf "$tmp/kit.tar.gz" -C "$tmp"
# The release tarball unpacks into scripts/, README.md, .gitignore at the root.
# We move its contents (not the wrapping dir) into TARGET_DIR.
shopt -s dotglob nullglob
for f in "$tmp"/*; do
    [[ "$(basename "$f")" == "kit.tar.gz" ]] && continue
    [[ "$(basename "$f")" == "kit.tar.gz.sha256" ]] && continue
    mv "$f" "$TARGET_DIR/"
done
shopt -u dotglob nullglob

cat <<REPORT

=================================================================
  aidlc-ops $tag_name installed at $TARGET_DIR
=================================================================

  Quick start:
    $TARGET_DIR/scripts/aidlc-bootstrap.sh --check         # audit any project
    $TARGET_DIR/scripts/aidlc-bootstrap-kit.sh --yes       # end-to-end install on a fresh project
    $TARGET_DIR/scripts/aidlc-switch-harness.sh --audit    # diagnostic before switching

  To upgrade later, just rerun this command — it always pulls the latest tag.
REPORT
