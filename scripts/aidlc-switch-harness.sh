#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# aidlc-switch-harness.sh
#
# Toggle AI-DLC harness for this project without losing workflow state.
# Use this when one harness runs out of credits (e.g. Claude Code quota) and
# you need to continue with the other (e.g. opencode) on the SAME checkout.
#
# Usage:
#   ./scripts/aidlc-switch-harness.sh [--force] <harness>
#
# Where <harness> is one of: claude | opencode | codex | cursor | kiro |
# kiro-ide | copilot
#
# Flags:
#   --force    Bypass the in-progress stage guard. Use only when the workflow
#              state is stale or the engine failed to transition markers after
#              a READY verdict (the script will log a loud warning). Inside
#              the new harness, run `/aidlc --resume` to reconcile.
#   --audit    Print a non-destructive diagnostic: which harness is configured
#              now, which one was last used, whether the active intent's state
#              is clean enough to switch, and the exact command to switch to
#              the most common alternative. Exits 0.
#
# What it does:
#   1. Validates the workflow state (refuses to switch mid-stage).
#   2. Refreshes the harness-specific projection from the installed runtime.
#   3. Runs `aidlc doctor` and reports the result.
#   4. Prints the next-step command to open the new harness.
#
# What it preserves (intentionally):
#   - aidlc/ workspace (intents, audit shards, memory, codekb) — never touched
#   - AGENTS.md (project-owned, custom content)
#   - .gitignore (project-owned, managed block already merged)
#   - .aidlc/.aidlc-clone-id (machine-local clone identity)
#   - .aidlc/.aidlc-sessions/ (per-conversation session→intent map)
#
# What it DOES NOT do:
#   - It will NOT switch if any intent is mid-stage ([ ]).
#   - It will NOT commit anything (you decide what to commit).
#   - It will NOT open the harness for you.
#   - It will NOT touch the other harness's tree (you must have closed it).
#
# ----------------------------------------------------------------------------
set -euo pipefail

# ---- args & preconditions -------------------------------------------------

FORCE=0
AUDIT_ONLY=0
while [[ "${1:-}" == "--"* ]]; do
    case "${1}" in
        --force) FORCE=1; shift ;;
        --audit) AUDIT_ONLY=1; shift ;;
        *) echo "error: unknown flag '${1}'" >&2
           echo "       valid: --force, --audit" >&2
           exit 2 ;;
    esac
done

# --audit without a TARGET is a pure diagnostic, not a switch.
if [[ $AUDIT_ONLY -eq 1 && -z "${1:-}" ]]; then
    readonly TARGET=""
else
    readonly TARGET="${1:?usage: $0 [--force|--audit] <claude|opencode|codex|cursor|kiro|kiro-ide|copilot>}"
fi

readonly VALID_HARNESSES=(claude opencode codex cursor kiro kiro-ide copilot)
is_valid=0
if [[ -n "$TARGET" ]]; then
    for h in "${VALID_HARNESSES[@]}"; do
        [[ "$h" == "$TARGET" ]] && is_valid=1 && break
    done
    if [[ $is_valid -eq 0 ]]; then
        echo "error: invalid harness '$TARGET'" >&2
        echo "       valid: ${VALID_HARNESSES[*]}" >&2
        exit 2
    fi
fi

# Resolve runtime root for the installed AIDLC version.
AIDLC_BIN="$(command -v aidlc || true)"
if [[ -z "$AIDLC_BIN" ]]; then
    echo "error: 'aidlc' not on PATH. Install with:" >&2
    echo "       curl -fsSL https://github.com/awslabs/aidlc-workflows/releases/latest/download/install.sh | sh" >&2
    exit 3
fi

# aidlc version reports the runtime version, which lives at
# ~/.local/share/aidlc/versions/<runtime>/runtime/<harness>/.
RUNTIME_VERSION=""
if "$AIDLC_BIN" version --json >/dev/null 2>&1; then
    RUNTIME_VERSION="$("$AIDLC_BIN" version --json 2>/dev/null \
        | grep -oE '"runtimeVersion"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -1 \
        | sed -E 's/.*"([^"]+)"$/\1/')"
fi
if [[ -z "$RUNTIME_VERSION" ]]; then
    AIDLC_INSTALL_ROOT="${AIDLC_INSTALL_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/aidlc}"
    RUNTIME_VERSION="$(cat "$AIDLC_INSTALL_ROOT/active-version" 2>/dev/null | tr -d '[:space:]' || true)"
fi
if [[ -z "$RUNTIME_VERSION" ]]; then
    echo "error: cannot resolve AIDLC runtime version." >&2
    echo "       tried: 'aidlc version --json' and active-version file." >&2
    exit 3
fi

AIDLC_INSTALL_ROOT="${AIDLC_INSTALL_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/aidlc}"
readonly RUNTIME_ROOT="$AIDLC_INSTALL_ROOT/versions/$RUNTIME_VERSION/runtime"
readonly RUNTIME_SRC="$RUNTIME_ROOT/$TARGET"

if [[ ! -d "$RUNTIME_SRC" ]]; then
    echo "error: runtime source not installed: $RUNTIME_SRC" >&2
    echo "       reinstall with the standard installer (it ships all harnesses)." >&2
    exit 3
fi

# Project root is the directory containing aidlc/ (the workspace).
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_ROOT"

# ---- state validator -------------------------------------------------------
#
# Reads the active intent's aidlc-state.md and refuses to switch if any stage
# is currently in-progress (symbol [ ]). Allows switching when the active
# stage is in a gate ([G]) or revising ([R]), with appropriate messaging.
#
# Symbols (per AIDLC state convention, see line 56 of any aidlc-state.md):
#   [ ]   not started      — not blocking
#   [-]   in-progress      — REFUSE to switch
#   [?]   awaiting approval — safe to switch (you decide the gate)
#   [R]   revising         — safe but warning (reviewer fingerprint at risk)
#   [x]   complete         — not blocking
#   [S]   skipped          — not blocking
#
# No active-intent file ⇒ no active workflow ⇒ safe to switch silently.
# ----------------------------------------------------------------------------

# emit_audit_diagnostic — non-destructive snapshot for the --audit flag.
# Reads the dot-dir presence, the active intent's audit log, and the state
# file counters (already populated by the caller), then prints a one-screen
# report and the exact command(s) to switch to the most common alternative.
emit_audit_diagnostic() {
    local configured="" last_used="" alt_harness="" alt_cmd_clean="" alt_cmd_force=""

    # 1. Configured harness — dot-dir presence at project root.
    for h in "${VALID_HARNESSES[@]}"; do
        if [[ -d ".$h" || ( "$h" == "opencode" && -f "opencode.json" ) ]]; then
            configured="$h"
            break
        fi
    done

    # 2. Last used — most recent SESSION_STARTED in the active intent's audit.
    #    The events carry `Path: .<harness>/rules/`, so we grep that field.
    if [[ -n "$ACTIVE_INTENT" ]]; then
        last_used=$(grep -hE '^\*\*Path\*\*: \.' \
            "aidlc/spaces/default/intents/$ACTIVE_INTENT/audit/"*.md 2>/dev/null \
            | sed -E 's|.*Path\*\*: \.([a-z-]+)/.*|\1|' \
            | grep -E "^(claude|opencode|codex|cursor|kiro|copilot)$" \
            | tail -1)
    fi

    # 3. State assessment.
    local state_label="CLEAN"
    if [[ $in_progress -gt 0 ]]; then
        state_label="STALE (markers stuck in [-])"
    elif [[ $in_revision -gt 0 ]]; then
        state_label="REVISING (reviewer fingerprint at risk)"
    elif [[ -z "$STATE_FILE" ]]; then
        state_label="NO ACTIVE INTENT"
    fi

    # 4. Pick the most common alternative to recommend. If configured is
    #    claude, suggest opencode; if opencode, suggest claude; otherwise
    #    the first installed alternative that isn't the configured one.
    if [[ "$configured" == "claude" ]]; then
        alt_harness="opencode"
    elif [[ "$configured" == "opencode" ]]; then
        alt_harness="claude"
    else
        for h in "${VALID_HARNESSES[@]}"; do
            [[ "$h" != "$configured" ]] && alt_harness="$h" && break
        done
    fi
    if [[ -n "$alt_harness" ]]; then
        alt_cmd_clean="$0 $alt_harness"
        alt_cmd_force="$0 --force $alt_harness"
    fi

    echo "================================================================="
    echo "  Harness diagnostic (--audit)"
    echo "================================================================="
    echo ""
    echo "  Configured now:    ${configured:-<none>}"
    if [[ -n "$configured" ]]; then
        echo "                    (detected from .$configured/ presence)"
    fi
    echo "  Last session:      ${last_used:-<no audit events yet>}"
    if [[ -n "$last_used" ]]; then
        echo "                    (latest SESSION_STARTED in audit)"
    fi
    echo "  Active intent:     ${ACTIVE_INTENT:-<none>}"
    echo "  State assessment:  $state_label"
    if [[ -n "$STATE_FILE" ]]; then
        echo "    Stages [-]:      $in_progress"
        echo "    Stages [?]:      $in_gate"
        echo "    Stages [R]:      $in_revision"
    fi
    echo ""
    if [[ $in_progress -gt 0 ]]; then
        echo "  Switch assessment: BLOCKED by in-progress stages."
        echo "                    Use --force to bypass (reconcile with"
        echo "                    /aidlc --resume inside the new harness)."
    else
        echo "  Switch assessment: SAFE — no in-progress stages."
    fi
    echo ""
    if [[ -n "$alt_cmd_clean" ]]; then
        echo "  To switch to $alt_harness:"
        if [[ $in_progress -gt 0 ]]; then
            echo "    $alt_cmd_force"
        else
            echo "    $alt_cmd_clean"
            echo "    $alt_cmd_force   # if you don't want to wait"
        fi
    fi
    echo ""
}

ACTIVE_INTENT=""
ACTIVE_INTENT_FILE="aidlc/spaces/default/intents/active-intent"
STATE_FILE=""

if [[ -f "$ACTIVE_INTENT_FILE" ]]; then
    ACTIVE_INTENT="$(cat "$ACTIVE_INTENT_FILE" | tr -d '[:space:]')"
    if [[ -n "$ACTIVE_INTENT" && "$ACTIVE_INTENT" != "default" ]]; then
        CANDIDATE="aidlc/spaces/default/intents/$ACTIVE_INTENT/aidlc-state.md"
        if [[ -f "$CANDIDATE" ]]; then
            STATE_FILE="$CANDIDATE"
        fi
    fi
fi

if [[ -z "$STATE_FILE" ]]; then
    if [[ $AUDIT_ONLY -eq 1 ]]; then
        in_progress=0
        in_gate=0
        in_revision=0
    else
        echo "→ no active intent; switching is safe."
    fi
else
    # Count stages by symbol. The state file uses single-char markers
    # inside square brackets: [-] in-progress, [?] gate, [R] revising.
    # We accept them in both bullet (- [-]) and table-cell (`| [-]`) form
    # because the renderer varies across stages.
    in_progress=$(grep -cE '\[-\]' "$STATE_FILE" 2>/dev/null || true)
    in_gate=$(grep -cE '\[\?\]' "$STATE_FILE" 2>/dev/null || true)
    in_revision=$(grep -cE '\[R\]' "$STATE_FILE" 2>/dev/null || true)
    in_progress=${in_progress:-0}
    in_gate=${in_gate:-0}
    in_revision=${in_revision:-0}

    # --audit short-circuit: print the diagnostic and exit 0 before the guard.
    if [[ $AUDIT_ONLY -eq 1 ]]; then
        emit_audit_diagnostic
        exit 0
    fi

    if [[ $in_progress -gt 0 ]]; then
        if [[ $FORCE -eq 1 ]]; then
            echo "================================================================="
            echo "  --force: bypassing in-progress guard."
            echo "================================================================="
            echo ""
            echo "  Intent:      $ACTIVE_INTENT"
            echo "  State file:  $STATE_FILE"
            echo "  Stages [-]:  $in_progress in-progress"
            echo ""
            echo "  The switch will proceed, but the workflow state may be"
            echo "  inconsistent on the other side. Run /aidlc --resume inside"
            echo "  the new harness to reconcile markers after the refresh."
            echo ""
        else
            echo "================================================================="
            echo "  REFUSING TO SWITCH: an intent is mid-stage."
            echo "================================================================="
            echo ""
            echo "  Intent:      $ACTIVE_INTENT"
            echo "  State file:  $STATE_FILE"
            echo "  Stages [-]:  $in_progress in-progress"
            echo ""
            echo "  Mid-stage switches corrupt sub-agent execution, invalidate"
            echo "  reviewer fingerprints, and can lose uncommitted artifacts."
            echo ""
            echo "  Wait for the active stage to reach a gate ([?]) and either"
            echo "  approve it or end your session there. Then re-run this script."
            echo ""
            echo "  If the markers are stale (READY verdict on file but [-] still"
            echo "  set, as happens after an engine bug), pass --force to bypass"
            echo "  this guard and reconcile state inside the new harness."
            echo ""
            echo "  Quick check: which stage is currently running?"
            echo "    grep -nE '\\[-\\]' \"$STATE_FILE\""
            echo ""
            exit 1
        fi
    fi

    if [[ $in_revision -gt 0 ]]; then
        echo "→ active intent has $in_revision stage(s) in revision ([R])."
        echo "  Switching now is mechanically safe but the reviewer fingerprint"
        echo "  on that revision may need a rebase after the switch."
    fi

    if [[ $in_gate -gt 0 ]]; then
        echo "→ active intent has $in_gate stage(s) awaiting your approval ([?])."
        echo "  This is the IDEAL moment to switch — no work is mid-flight."
    fi
fi

# If --audit was passed but there was no active intent, still emit the
# diagnostic (now with the empty-state counts we initialized above).
if [[ $AUDIT_ONLY -eq 1 ]]; then
    emit_audit_diagnostic
    exit 0
fi

# ---- refresh the harness projection ---------------------------------------
#
# Strategy: copy the engine surface (.aidlc/, harness dot-dir, root config)
# from the runtime source onto the project. The runtime source is the
# canonical truth for the installed AIDLC version; project-owned files
# (AGENTS.md, .gitignore, aidlc/ workspace) are not touched.
#
# Why we don't just run `aidlc config --harness <TARGET> --from <SRC>`:
#   - In copy-channel installs the binary lacks the --harness switch and
#     refuses a refresh that would change the detected distribution.
#   - The manual refresh below is what the binary would do internally, and
#     it preserves the same machine-locals (.aidlc/.aidlc-clone-id, sessions).
# ----------------------------------------------------------------------------

echo "→ refreshing engine from $RUNTIME_SRC"

# 1. Engine tree — replace sub-dirs wholesale with the runtime version, but
#    preserve machine-locals that exist only on this clone.
for sub in tools hooks skills agents sensors aidlc-common scopes; do
    if [[ -d "$RUNTIME_SRC/.aidlc/$sub" ]]; then
        rm -rf ".aidlc/$sub"
        cp -rT "$RUNTIME_SRC/.aidlc/$sub" ".aidlc/$sub"
    fi
done

# 2. Harness-specific tree — only the one we're switching TO.
case "$TARGET" in
    opencode)
        [[ -d "$RUNTIME_SRC/.opencode" ]] && {
            rm -rf ".opencode"
            cp -rT "$RUNTIME_SRC/.opencode" ".opencode"
        }
        [[ -f "$RUNTIME_SRC/opencode.json" ]] && cp "$RUNTIME_SRC/opencode.json" "opencode.json"
        ;;
    claude)
        [[ -d "$RUNTIME_SRC/.claude" ]] && {
            rm -rf ".claude"
            cp -rT "$RUNTIME_SRC/.claude" ".claude"
        }
        ;;
    codex)
        [[ -d "$RUNTIME_SRC/.codex" ]] && {
            rm -rf ".codex"
            cp -rT "$RUNTIME_SRC/.codex" ".codex"
        }
        ;;
    cursor|kiro|kiro-ide|copilot)
        # These harnesses use the harness's own dot-dir + root config; copy
        # whatever the runtime ships without hard-coding paths.
        for entry in "$RUNTIME_SRC"/.* "$RUNTIME_SRC"/*; do
            name="$(basename "$entry")"
            case "$name" in
                .|.aidlc|aidlc|AGENTS.md|.gitignore|package.json) continue ;;
            esac
            rm -rf "$name"
            cp -rT "$entry" "$name"
        done
        ;;
esac

# 3. Sanity: machine-locals should still be present (we never delete them,
#    only skip refresh of their containing dirs).
if [[ ! -f "aidlc/.aidlc-clone-id" ]]; then
    echo "warning: aidlc/.aidlc-clone-id missing after refresh." >&2
    echo "         this clone's audit shard identity has been lost." >&2
    echo "         fix: re-init with 'aidlc --init' if subsequent stages fail." >&2
fi

# ---- post-refresh validation ----------------------------------------------

echo "→ running aidlc doctor"
if aidlc doctor >/tmp/aidlc-switch-harness.doctor.log 2>&1; then
    tail -1 /tmp/aidlc-switch-harness.doctor.log
else
    echo "warning: aidlc doctor reported issues. See /tmp/aidlc-switch-harness.doctor.log"
    tail -20 /tmp/aidlc-switch-harness.doctor.log
fi

echo ""
echo "================================================================="
echo "  Harness switched to: $TARGET"
echo "================================================================="
echo ""
echo "  Next:"
case "$TARGET" in
    opencode) echo "    opencode    # or: opencode run --command aidlc" ;;
    claude)    echo "    claude      # then /aidlc --resume" ;;
    codex)     echo "    codex       # then \$aidlc --resume" ;;
    cursor)    echo "    cursor      # or run 'agent' in this project" ;;
    kiro)      echo "    kiro-cli chat" ;;
    kiro-ide)  echo "    open the project in Kiro IDE" ;;
    copilot)   echo "    copilot     # or open VS Code with Copilot" ;;
esac
echo ""
echo "  Inside the harness, run /aidlc --resume to pick up the active intent."
echo ""
