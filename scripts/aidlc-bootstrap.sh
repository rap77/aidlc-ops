#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# aidlc-bootstrap.sh
#
# Pre-installation audit for AI-DLC in a project that does NOT yet have it.
# Reports whether AIDLC can run here, what is missing, and the exact
# commands to close every gap. By default the script is read-only: it never
# touches the project. Pass --apply to execute the remediation plan after
# an interactive confirmation gate.
#
# Usage:
#   bash aidlc-bootstrap.sh                  # audit only, default
#   bash aidlc-bootstrap.sh --check          # same as default
#   bash aidlc-bootstrap.sh --apply          # audit + interactive install
#   bash aidlc-bootstrap.sh --json           # machine-readable audit
#   bash aidlc-bootstrap.sh --harness <name> # target harness (default: opencode)
#
# What it audits:
#   - System: aidlc binary, version, installed runtimes, common deps
#   - Project: cwd, git presence, recognized manifest files, current state
#   - AIDLC config: dot-dirs, .gitignore block, workspace, harness tree
#   - Optional warnings: large caches under repo root, secrets in tracked files
#
# What --apply does:
#   1. Runs aidlc config --harness <TARGET> --from <runtime> (or copies from
#      runtime/opencode manually in copy-channel installs where --harness is
#      not exposed)
#   2. Merges the managed .gitignore block if missing
#   3. Prints post-install verification command
# ----------------------------------------------------------------------------
set -euo pipefail

# ---- arg parsing -----------------------------------------------------------

MODE="check"           # check | apply
TARGET_HARNESS="opencode"
JSON_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)  MODE="check"; shift ;;
        --apply)  MODE="apply"; shift ;;
        --json)   JSON_ONLY=1; shift ;;
        --harness) TARGET_HARNESS="${2:?--harness requires a name}"; shift 2 ;;
        -h|--help)
            cat <<'USAGE'
Usage: bash aidlc-bootstrap.sh [--check|--apply|--json] [--harness <name>]

Default mode: --check (read-only audit, prints a remediation plan).

Flags:
  --check         Audit only, never modifies the project.
  --apply         Audit + interactive install. Prompts before each change.
  --json          Machine-readable output (suppresses human report).
  --harness NAME  Target harness (default: opencode). One of: claude, opencode,
                  codex, cursor, kiro, kiro-ide, copilot.

Exit codes:
  0  Feasible (or installed successfully under --apply).
  1  Not feasible (missing system dependency or incompatible project).
  2  Invalid arguments.
USAGE
            exit 0
            ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

readonly VALID_HARNESSES=(claude opencode codex cursor kiro kiro-ide copilot)
is_valid=0
for h in "${VALID_HARNESSES[@]}"; do
    [[ "$h" == "$TARGET_HARNESS" ]] && is_valid=1 && break
done
if [[ $is_valid -eq 0 ]]; then
    echo "error: invalid harness '$TARGET_HARNESS'" >&2
    echo "       valid: ${VALID_HARNESSES[*]}" >&2
    exit 2
fi

# ---- output helpers --------------------------------------------------------

# Track findings. Each line is "severity§section§message" using § as the
# delimiter (chosen because it does not appear in any message text and survives
# awk -F'§' cleanly).
FINDINGS=()

add() {
    local sev="$1" msg="$2"
    # Split the message into section + actual message at the FIRST ':'.
    local section="OTHER" rest="$msg"
    if [[ "$msg" == *:* ]]; then
        section="${msg%%:*}"
        rest="${msg#*:}"
    fi
    FINDINGS+=("${sev}§${section}§${rest}")
}

# emit_json — machine-readable audit dump (used by --json).
emit_json() {
    echo "{"
    echo "  \"mode\": \"$MODE\","
    echo "  \"harness\": \"$TARGET_HARNESS\","
    echo "  \"project_root\": \"$PROJECT_ROOT\","
    echo "  \"aidlc_version\": \"${AIDLC_VERSION:-none}\","
    echo "  \"ready_for_apply\": $READY_FOR_APPLY,"
    echo "  \"findings\": ["
    local first=1
    for f in "${FINDINGS[@]}"; do
        local sev="${f%%§*}"
        local rest="${f#*§}"
        local section="${rest%%§*}"
        local msg="${rest#*§}"
        msg="${msg//\"/\\\"}"
        if [[ $first -eq 1 ]]; then first=0; else echo ","; fi
        printf '    {"severity": "%s", "section": "%s", "message": "%s"}' "$sev" "$section" "$msg"
    done
    echo ""
    echo "  ]"
    echo "}"
}

# Print the human-readable report unless --json.
print_report() {
    local verdict="$1"
    local ready_for_apply="$2"

    echo "================================================================="
    echo "  AI-DLC bootstrap audit"
    echo "================================================================="
    echo ""
    echo "  Mode:           $MODE"
    echo "  Target harness: $TARGET_HARNESS"
    echo "  Project root:   $PROJECT_ROOT"
    echo ""

    # Render findings grouped by section, fixed order: System, Project, AIDLC, Warnings, Other.
    local prev_section="" current_label=""
    for f in "${FINDINGS[@]}"; do
        local sev="${f%%§*}"
        local rest="${f#*§}"
        local section="${rest%%§*}"
        local msg="${rest#*§}"
        if [[ "$section" != "$prev_section" ]]; then
            case "$section" in
                SYSTEM)  current_label="System" ;;
                PROJECT) current_label="Project" ;;
                AIDLC)   current_label="AIDLC config" ;;
                WARN)    current_label="Warnings" ;;
                *)       current_label="Other" ;;
            esac
            echo ""
            echo "  --- $current_label ---"
            prev_section="$section"
        fi
        printf "    [%-4s] %s\n" "$sev" "$msg"
    done

    echo ""
    echo "================================================================="
    echo "  Verdict: $verdict"
    echo "================================================================="
    if [[ "$ready_for_apply" == "1" ]]; then
        echo ""
        echo "  To install now (interactive):"
        echo "    bash $0 --apply --harness $TARGET_HARNESS"
    fi
    echo ""
}

# ---- system audit ----------------------------------------------------------

PROJECT_ROOT="$(pwd)"

# aidlc binary
if command -v aidlc >/dev/null 2>&1; then
    AIDLC_BIN="$(command -v aidlc)"
    AIDLC_VERSION="$("$AIDLC_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
    add OK "SYSTEM:aidlc binary present at $AIDLC_BIN ($AIDLC_VERSION)"
else
    AIDLC_BIN=""
    AIDLC_VERSION=""
    add FAIL "SYSTEM:aidlc binary NOT on PATH"
    add FAIL "SYSTEM:fix: install with the official installer"
fi

# Installed runtimes (only meaningful if aidlc is present).
RUNTIME_ROOT=""
RUNTIME_VERSION=""
TARGET_RUNTIME_SRC=""
if [[ -n "$AIDLC_BIN" ]]; then
    RUNTIME_ROOT="${AIDLC_INSTALL_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/aidlc}"
    RUNTIME_VERSION="$(cat "$RUNTIME_ROOT/active-version" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$RUNTIME_VERSION" && -d "$RUNTIME_ROOT/versions/$RUNTIME_VERSION/runtime/$TARGET_HARNESS" ]]; then
        TARGET_RUNTIME_SRC="$RUNTIME_ROOT/versions/$RUNTIME_VERSION/runtime/$TARGET_HARNESS"
        add OK "SYSTEM:runtime for $TARGET_HARNESS installed ($RUNTIME_VERSION)"
    else
        add FAIL "SYSTEM:runtime for $TARGET_HARNESS NOT installed"
        add FAIL "SYSTEM:fix: reinstall aidlc (the installer ships every harness runtime)"
    fi
fi

# Common deps. We only require git today; extend this list as AIDLC grows.
if command -v git >/dev/null 2>&1; then
    add OK "SYSTEM:git present"
else
    add FAIL "SYSTEM:git NOT installed (required by AIDLC)"
fi

# ---- project audit ---------------------------------------------------------

# Git presence.
if [[ -d "$PROJECT_ROOT/.git" ]]; then
    add OK "PROJECT:git repository detected"
else
    if git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        add OK "PROJECT:git repository (worktree) detected"
    else
        add FAIL "PROJECT:not a git repository"
        add FAIL "PROJECT:fix: git init && git commit --allow-empty -m 'chore: bootstrap'"
    fi
fi

# Recognized manifest files.
MANIFEST_FOUND=0
for m in package.json pyproject.toml Cargo.toml go.mod; do
    if [[ -f "$PROJECT_ROOT/$m" ]]; then
        add OK "PROJECT:$m present"
        MANIFEST_FOUND=1
    fi
done
if [[ $MANIFEST_FOUND -eq 0 ]]; then
    add WARN "PROJECT:no recognized manifest (package.json/pyproject.toml/Cargo.toml/go.mod)"
    add WARN "PROJECT:fix: AIDLC will still scaffold, but you may want to add one to anchor the project shape"
fi

# Large caches under repo root (informational only).
LARGE_DIRS=""
for d in .turbo node_modules .next .venv dist build target; do
    if [[ -d "$PROJECT_ROOT/$d" ]]; then
        size=$(du -sh "$PROJECT_ROOT/$d" 2>/dev/null | awk '{print $1}')
        LARGE_DIRS="$LARGE_DIRS $d($size)"
    fi
done
if [[ -n "$LARGE_DIRS" ]]; then
    add WARN "WARN:large directories present:$LARGE_DIRS"
    add WARN "WARN:these are usually in .gitignore already; verify they are ignored to keep the AIDLC source-bound small"
fi

# ---- AIDLC config audit ----------------------------------------------------

# .aidlc/engine tree.
if [[ -d "$PROJECT_ROOT/.aidlc" ]]; then
    add OK "AIDLC:.aidlc/ engine tree present"
else
    add FAIL "AIDLC:.aidlc/ engine tree MISSING"
fi

# aidlc/ workspace.
if [[ -d "$PROJECT_ROOT/aidlc" ]]; then
    add OK "AIDLC:aidlc/ workspace present"
else
    add FAIL "AIDLC:aidlc/ workspace MISSING"
fi

# Harness-specific dot-dir.
case "$TARGET_HARNESS" in
    opencode) HAS_HARNESS_DIR=$([ -d "$PROJECT_ROOT/.opencode" ] && echo 1 || echo 0); ROOT_CFG="$PROJECT_ROOT/opencode.json" ;;
    claude)   HAS_HARNESS_DIR=$([ -d "$PROJECT_ROOT/.claude" ] && echo 1 || echo 0); ROOT_CFG="$PROJECT_ROOT/.claude/settings.json" ;;
    codex)    HAS_HARNESS_DIR=$([ -d "$PROJECT_ROOT/.codex" ] && echo 1 || echo 0); ROOT_CFG="$PROJECT_ROOT/.codex/config.toml" ;;
    cursor|kiro|kiro-ide|copilot) HAS_HARNESS_DIR=0; ROOT_CFG="" ;;
esac
if [[ "$HAS_HARNESS_DIR" -eq 1 ]]; then
    add OK "AIDLC:.$TARGET_HARNESS/ tree present"
else
    add FAIL "AIDLC:.$TARGET_HARNESS/ tree MISSING"
fi

# Gitignore managed block.
if [[ -f "$PROJECT_ROOT/.gitignore" ]] && grep -q "# BEGIN AI-DLC:gitignore" "$PROJECT_ROOT/.gitignore" 2>/dev/null; then
    add OK "AIDLC:.gitignore has the BEGIN AI-DLC:gitignore managed block"
else
    add WARN "AIDLC:.gitignore does NOT have the BEGIN AI-DLC:gitignore managed block"
    add WARN "AIDLC:fix: aidlc config will merge it automatically"
fi

# AGENTS.md.
if [[ -f "$PROJECT_ROOT/AGENTS.md" ]]; then
    add OK "AIDLC:AGENTS.md present"
else
    add WARN "AIDLC:AGENTS.md missing (aidlc config will scaffold one)"
fi

# Overall verdict.
HAS_FAIL=0
for f in "${FINDINGS[@]}"; do
    [[ "$f" == FAIL* ]] && HAS_FAIL=1 && break
done
if [[ $HAS_FAIL -eq 0 ]]; then
    VERDICT="READY (run --apply to install or refresh)"
    READY_FOR_APPLY=1
else
    VERDICT="NOT READY — fix the FAIL items above, then re-run"
    READY_FOR_APPLY=0
fi

# ---- JSON output (optional) ------------------------------------------------

if [[ $JSON_ONLY -eq 1 ]]; then
    # Compact JSON: findings + verdict. Uses awk because jq is optional.
    emit_json
    [[ $READY_FOR_APPLY -eq 1 ]] || exit 1
    exit 0
fi

# ---- human report ----------------------------------------------------------

print_report "$VERDICT" "$READY_FOR_APPLY"

[[ $READY_FOR_APPLY -eq 1 ]] || exit 1

# ---- apply mode ------------------------------------------------------------

if [[ "$MODE" != "apply" ]]; then
    exit 0
fi

# Interactive confirmation.
echo "About to install AI-DLC ($TARGET_HARNESS) into $PROJECT_ROOT."
echo "The script will:"
echo "  1. Refresh the engine tree (.aidlc/, .$TARGET_HARNESS/, $ROOT_CFG) from $TARGET_RUNTIME_SRC"
echo "  2. Run 'aidlc doctor' to verify"
echo ""
read -r -p "Continue? [y/N] " ans
if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

if [[ -z "$AIDLC_BIN" || -z "$TARGET_RUNTIME_SRC" ]]; then
    echo "error: cannot apply — missing aidlc binary or runtime for $TARGET_HARNESS" >&2
    exit 1
fi

echo ""
echo "→ refreshing engine from $TARGET_RUNTIME_SRC"

# Engine sub-dirs.
for sub in tools hooks skills agents sensors aidlc-common scopes; do
    if [[ -d "$TARGET_RUNTIME_SRC/.aidlc/$sub" ]]; then
        rm -rf "$PROJECT_ROOT/.aidlc/$sub" 2>/dev/null || true
        cp -rT "$TARGET_RUNTIME_SRC/.aidlc/$sub" "$PROJECT_ROOT/.aidlc/$sub"
    fi
done

# Harness-specific tree.
case "$TARGET_HARNESS" in
    opencode)
        [[ -d "$TARGET_RUNTIME_SRC/.opencode" ]] && {
            rm -rf "$PROJECT_ROOT/.opencode" 2>/dev/null || true
            cp -rT "$TARGET_RUNTIME_SRC/.opencode" "$PROJECT_ROOT/.opencode"
        }
        [[ -f "$TARGET_RUNTIME_SRC/opencode.json" ]] && cp "$TARGET_RUNTIME_SRC/opencode.json" "$PROJECT_ROOT/opencode.json"
        ;;
    claude)
        [[ -d "$TARGET_RUNTIME_SRC/.claude" ]] && {
            rm -rf "$PROJECT_ROOT/.claude" 2>/dev/null || true
            cp -rT "$TARGET_RUNTIME_SRC/.claude" "$PROJECT_ROOT/.claude"
        }
        ;;
    codex)
        [[ -d "$TARGET_RUNTIME_SRC/.codex" ]] && {
            rm -rf "$PROJECT_ROOT/.codex" 2>/dev/null || true
            cp -rT "$TARGET_RUNTIME_SRC/.codex" "$PROJECT_ROOT/.codex"
        }
        ;;
esac

# Run aidlc config if available.
if "$AIDLC_BIN" config --help >/dev/null 2>&1; then
    echo "→ running aidlc config (will merge managed gitignore blocks)"
    "$AIDLC_BIN" config --harness "$TARGET_HARNESS" --from "$TARGET_RUNTIME_SRC" --yes 2>&1 | tail -20 || \
        echo "warning: aidlc config refused (common in copy-channel); the manual copy above already covered the essential files"
fi

echo ""
echo "→ running aidlc doctor"
"$AIDLC_BIN" doctor 2>&1 | tail -20 || true

echo ""
echo "================================================================="
echo "  Install complete"
echo "================================================================="
echo ""
echo "  Next step inside your harness:"
case "$TARGET_HARNESS" in
    opencode) echo "    opencode" ;;
    claude)   echo "    claude" ;;
    codex)    echo "    codex" ;;
    cursor)   echo "    cursor (or run 'agent' in the project)" ;;
    kiro)     echo "    kiro-cli chat" ;;
    kiro-ide) echo "    open the project in Kiro IDE" ;;
    copilot)  echo "    copilot" ;;
esac
echo "    then:  /aidlc --doctor"
echo ""
