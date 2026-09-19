#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# aidlc-bootstrap-kit.sh
#
# End-to-end installer for a project that does NOT yet have AI-DLC. Closes
# the chicken-and-egg gap left by aidlc-bootstrap.sh (which assumes aidlc
# is already on PATH): this script installs aidlc itself if missing, then
# runs the feasibility audit + optional install, then offers to drop the
# harness toggle into the project for future use.
#
# Usage:
#   bash aidlc-bootstrap-kit.sh                          # interactive
#   bash aidlc-bootstrap-kit.sh --harness opencode        # default harness
#   bash aidlc-bootstrap-kit.sh --no-aidlc-install       # assume aidlc present
#   bash aidlc-bootstrap-kit.sh --no-toggle              # skip the toggle copy
#
# Phases (interactive by default; --yes accepts every prompt):
#   Phase 1: ensure aidlc binary is on PATH (install via the official installer)
#   Phase 2: audit feasibility (calls aidlc-bootstrap.sh --check)
#   Phase 3: install AIDLC into the project (calls aidlc-bootstrap.sh --apply)
#   Phase 4: copy the harness toggle into scripts/ (calls install-aidlc-switch-harness.sh)
#
# Exit codes:
#   0  All requested phases completed.
#   1  A phase refused (e.g., not feasible).
#   2  Invalid arguments.
# ----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$SCRIPT_DIR/aidlc-bootstrap.sh"
INSTALL_TOGGLE="$SCRIPT_DIR/install-aidlc-switch-harness.sh"

# ---- arg parsing -----------------------------------------------------------

TARGET_HARNESS="opencode"
INSTALL_AIDLC=1     # 1 = offer to install aidlc if missing
INSTALL_TOGGLE_FLAG=1 # 1 = offer to copy the toggle after bootstrap
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --harness) TARGET_HARNESS="${2:?--harness requires a name}"; shift 2 ;;
        --no-aidlc-install) INSTALL_AIDLC=0; shift ;;
        --no-toggle) INSTALL_TOGGLE_FLAG=0; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        -h|--help)
            cat <<'USAGE'
Usage: bash aidlc-bootstrap-kit.sh [options]

End-to-end installer for AI-DLC on a fresh project. Closes the gap left by
aidlc-bootstrap.sh (which requires aidlc on PATH) by installing aidlc first
when missing.

Options:
  --harness NAME        Target harness (default: opencode).
  --no-aidlc-install    Skip Phase 1 (assume aidlc already on PATH).
  --no-toggle           Skip Phase 4 (do not copy the harness toggle).
  --yes, -y             Accept every interactive prompt.

Phases:
  1. Install aidlc via the official installer (if missing).
  2. Audit feasibility with aidlc-bootstrap.sh --check.
  3. Install AIDLC into the project with aidlc-bootstrap.sh --apply.
  4. Copy aidlc-switch-harness.sh into the project's scripts/.
USAGE
            exit 0
            ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

ask_yes() {
    local prompt="$1"
    if [[ $ASSUME_YES -eq 1 ]]; then
        echo "$prompt [auto-yes]"
        return 0
    fi
    local ans
    read -r -p "$prompt [y/N] " ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ---- phase 0: preconditions ------------------------------------------------

if [[ ! -f "$BOOTSTRAP" || ! -f "$INSTALL_TOGGLE" ]]; then
    echo "error: this kit must live next to aidlc-bootstrap.sh and install-aidlc-switch-harness.sh" >&2
    echo "       missing: $([[ ! -f "$BOOTSTRAP" ]] && echo "$BOOTSTRAP ")$([[ ! -f "$INSTALL_TOGGLE" ]] && echo "$INSTALL_TOGGLE ")" >&2
    exit 3
fi

PROJECT_ROOT="$(pwd)"
echo "================================================================="
echo "  AI-DLC bootstrap kit"
echo "================================================================="
echo "  Project: $PROJECT_ROOT"
echo "  Harness: $TARGET_HARNESS"
echo ""

# ---- phase 1: aidlc on PATH ------------------------------------------------

if ! command -v aidlc >/dev/null 2>&1; then
    echo "Phase 1: aidlc binary NOT on PATH."
    if [[ $INSTALL_AIDLC -eq 0 ]]; then
        echo "error: --no-aidlc-install set but aidlc is missing; re-run without that flag" >&2
        exit 1
    fi
    echo "  The official installer downloads aidlc and every harness runtime to"
    echo "  ~/.local/share/aidlc/, then links ~/.local/bin/aidlc. It does not"
    echo "  require sudo. Source: github.com/awslabs/aidlc-workflows/releases."
    echo ""
    if ask_yes "Install aidlc now via the official installer?"; then
        tmp="$(mktemp -d)"
        curl -fsSL https://github.com/awslabs/aidlc-workflows/releases/latest/download/install.sh \
            -o "$tmp/install.sh"
        sh "$tmp/install.sh"
        rm -rf "$tmp"
        if ! command -v aidlc >/dev/null 2>&1; then
            echo ""
            echo "warning: aidlc still not on PATH after install. You may need to"
            echo "         open a new shell or run: export PATH=\"\$HOME/.local/bin:\$PATH\""
        fi
    else
        echo "Aborted: aidlc is required before this kit can do anything useful."
        exit 1
    fi
else
    echo "Phase 1: aidlc already on PATH ($(aidlc version 2>/dev/null | head -1))"
fi
echo ""

# ---- phase 2: audit --------------------------------------------------------

echo "Phase 2: feasibility audit"
echo ""
if ! bash "$BOOTSTRAP" --check --harness "$TARGET_HARNESS"; then
    echo ""
    echo "Phase 2 reported items that must be fixed by hand before install."
    echo "Re-run this kit after addressing them."
    exit 1
fi
echo ""

# ---- phase 3: install ------------------------------------------------------

echo "Phase 3: install AIDLC into the project"
echo ""
if ask_yes "Run aidlc-bootstrap --apply now?"; then
    bash "$BOOTSTRAP" --apply --harness "$TARGET_HARNESS"
else
    echo "Skipped Phase 3. Re-run the kit (or 'aidlc-bootstrap.sh --apply') to install later."
    exit 0
fi
echo ""

# ---- phase 4: copy toggle --------------------------------------------------

if [[ $INSTALL_TOGGLE_FLAG -eq 1 ]]; then
    echo "Phase 4: copy harness toggle into scripts/"
    echo ""
    if [[ -f "$PROJECT_ROOT/scripts/aidlc-switch-harness.sh" ]]; then
        echo "  scripts/aidlc-switch-harness.sh already present; skipping copy."
    else
        if ask_yes "Install scripts/aidlc-switch-harness.sh for future harness toggles?"; then
            bash "$INSTALL_TOGGLE" "$PROJECT_ROOT"
        else
            echo "  Skipped. You can copy it later with:"
            echo "    bash $INSTALL_TOGGLE $PROJECT_ROOT"
        fi
    fi
fi

echo ""
echo "================================================================="
echo "  Kit complete"
echo "================================================================="
echo ""
echo "  Next steps:"
echo "    cd $PROJECT_ROOT"
echo "    ./scripts/aidlc-switch-harness.sh --audit"
echo ""
