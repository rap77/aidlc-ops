#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# install-aidlc-switch-harness.sh
#
# Portable installer for the AIDLC harness switcher. Copies the toggle
# script (aidlc-switch-harness.sh) from THIS repo into the target project's
# scripts/ directory, validates the target has AIDLC installed, marks the
# new file executable, and prints the command to run it.
#
# Usage:
#   bash install-aidlc-switch-harness.sh <target-project-path>
#   curl -fsSL <raw-url> | bash -s -- <target-project-path>
#
# What it does:
#   1. Resolves the source path to aidlc-switch-harness.sh (next to this file).
#   2. Resolves the target project root.
#   3. Validates the target has an AIDLC workspace (aidlc/ directory present).
#   4. Creates target/scripts/ if missing.
#   5. Copies aidlc-switch-harness.sh there, chmod +x, refuses to overwrite
#      unless --force is passed.
#   6. Prints the install location and a one-liner to run --audit.
#
# Flags:
#   --force    Overwrite an existing aidlc-switch-harness.sh in the target.
# ----------------------------------------------------------------------------
set -euo pipefail

# ---- arg parsing -----------------------------------------------------------

FORCE=0
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        -h|--help)
            cat <<'USAGE'
Usage: bash install-aidlc-switch-harness.sh [--force] <target-project-path>

Copies scripts/aidlc-switch-harness.sh from this repo into <target>/scripts/,
validates the target has AIDLC installed, and chmods the copy +x.

Flags:
  --force    Overwrite an existing aidlc-switch-harness.sh in the target.

Example:
  bash install-aidlc-switch-harness.sh ~/projects/another-app
USAGE
            exit 0
            ;;
        -*)
            echo "error: unknown flag '$1'" >&2
            exit 2
            ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo "error: target project path is required" >&2
    echo "usage: $0 [--force] <target-project-path>" >&2
    exit 2
fi

# ---- resolve paths ---------------------------------------------------------

# Source script lives next to this installer.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/aidlc-switch-harness.sh"

if [[ ! -f "$SOURCE" ]]; then
    echo "error: source script not found at $SOURCE" >&2
    echo "       this installer must live next to aidlc-switch-harness.sh" >&2
    exit 3
fi

# Target: absolute path, must exist.
if [[ ! -d "$TARGET" ]]; then
    echo "error: target directory does not exist: $TARGET" >&2
    exit 3
fi
TARGET="$(cd "$TARGET" && pwd)"

# ---- validate target has AIDLC --------------------------------------------

if [[ ! -d "$TARGET/aidlc" ]]; then
    echo "error: $TARGET does not look like an AIDLC project" >&2
    echo "       (no aidlc/ workspace directory found)" >&2
    echo "       install AIDLC first: https://github.com/awslabs/aidlc-workflows" >&2
    exit 4
fi

# ---- copy ------------------------------------------------------------------

DEST_DIR="$TARGET/scripts"
DEST="$DEST_DIR/aidlc-switch-harness.sh"

mkdir -p "$DEST_DIR"

if [[ -f "$DEST" && $FORCE -eq 0 ]]; then
    echo "error: $DEST already exists. Re-run with --force to overwrite." >&2
    exit 5
fi

cp "$SOURCE" "$DEST"
chmod +x "$DEST"

# ---- report ----------------------------------------------------------------

cat <<REPORT

=================================================================
  Install complete
=================================================================

  Source: $SOURCE
  Target: $DEST

  Try it without switching anything:
    $DEST --audit

REPORT
