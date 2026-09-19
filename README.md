# aidlc-ops

Portable AI-DLC operations kit. Four bash scripts that cover the lifecycle of using [AI-DLC](https://github.com/awslabs/aidlc-workflows) (AI-Driven Development Life Cycle) across projects and harnesses.

## Scripts

| Script | Purpose | Use when |
|---|---|---|
| `scripts/aidlc-bootstrap-kit.sh` | End-to-end installer | You have a fresh project with no AIDLC. Closes the chicken-and-egg gap by installing `aidlc` itself if missing, then bootstrapping the project. |
| `scripts/aidlc-bootstrap.sh` | Pre-install feasibility audit | Project may or may not have AIDLC; you want a structured report of what's missing and the exact commands to fix it. Supports `--check` (read-only), `--apply` (interactive install), `--json`, `--harness NAME`. |
| `scripts/install-aidlc-switch-harness.sh` | Copy the toggle to another project | Target project already has AIDLC; you want the harness switcher available there. |
| `scripts/aidlc-switch-harness.sh` | Toggle between harnesses mid-workflow | Switch Claude ↔ opencode (or any other installed harness) without losing workflow state. Supports `--audit` (non-destructive diagnostic) and `--force` (bypass stale in-progress guard). |

## When to use which

```
You have a project. What's the situation?
├── No AIDLC at all
│   └── bash scripts/aidlc-bootstrap-kit.sh --yes
│       (installs aidlc + bootstraps project + copies the toggle)
│
├── AIDLC installed, want to verify it
│   └── bash scripts/aidlc-bootstrap.sh --check
│
├── AIDLC installed, which harness is active / can I switch?
│   └── bash scripts/aidlc-switch-harness.sh --audit
│
├── AIDLC installed, want to switch harness
│   ├── clean state:    bash scripts/aidlc-switch-harness.sh <target>
│   └── stale markers:  bash scripts/aidlc-switch-harness.sh --force <target>
│
└── Another project has AIDLC, copy the toggle into it
    └── bash scripts/install-aidlc-switch-harness.sh ~/path/to/target
```

## One-line remote install

From any machine that can reach the raw GitHub content:

```bash
# Audit only (no install)
curl -fsSL https://raw.githubusercontent.com/rap77/aidlc-ops/main/scripts/aidlc-bootstrap.sh | bash

# End-to-end install
curl -fsSL https://raw.githubusercontent.com/rap77/aidlc-ops/main/scripts/aidlc-bootstrap-kit.sh | bash -s -- --yes

# Copy the toggle to another project
curl -fsSL https://raw.githubusercontent.com/rap77/aidlc-ops/main/scripts/install-aidlc-switch-harness.sh | bash -s -- ~/projects/another-app
```

## Harness support

All scripts work with any AIDLC harness: `claude`, `opencode`, `codex`, `cursor`, `kiro`, `kiro-ide`, `copilot`. Default harness is `opencode`; override with `--harness NAME`.

## Requirements

- `bash` 4+ (uses associative arrays in `aidlc-bootstrap.sh`)
- `curl` (only for `--apply` mode of `aidlc-bootstrap-kit.sh`)
- `git` (project-level dependency of AIDLC itself)

The scripts do not require `aidlc` to be installed — `aidlc-bootstrap-kit.sh` handles that case.

## License

MIT-0 (same as upstream AIDLC).

## Upstream

[awslabs/aidlc-workflows](https://github.com/awslabs/aidlc-workflows) — the AI-DLC methodology and engine. This repo is operations tooling built on top of it.
