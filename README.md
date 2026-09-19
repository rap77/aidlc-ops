# aidlc-ops

Portable AI-DLC operations kit. Four bash scripts that cover the lifecycle of using [AI-DLC](https://github.com/awslabs/aidlc-workflows) (AI-Driven Development Life Cycle) across projects and harnesses.

## Status

| | |
|---|---|
| **Latest release** | [v0.1.0](https://github.com/rap77/aidlc-ops/releases/tag/v0.1.0) |
| **CI** | [![shellcheck](https://github.com/rap77/aidlc-ops/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/rap77/aidlc-ops/actions/workflows/shellcheck.yml) |
| **License** | MIT-0 |

## Scripts

| Script | Purpose | Use when |
|---|---|---|
| `scripts/aidlc-bootstrap-kit.sh` | End-to-end installer | You have a fresh project with no AIDLC. Closes the chicken-and-egg gap by installing `aidlc` itself if missing, then bootstrapping the project. |
| `scripts/aidlc-bootstrap.sh` | Pre-install feasibility audit | Project may or may not have AIDLC; you want a structured report of what's missing and the exact commands to fix it. Supports `--check` (read-only), `--apply` (interactive install), `--json`, `--harness NAME`. |
| `scripts/install-aidlc-switch-harness.sh` | Copy the toggle to another project | Target project already has AIDLC; you want the harness switcher available there. |
| `scripts/aidlc-switch-harness.sh` | Toggle between harnesses mid-workflow | Switch Claude ↔ opencode (or any other installed harness) without losing workflow state. Supports `--audit` (non-destructive diagnostic) and `--force` (bypass stale in-progress guard). |

## Decision tree

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

## One-line install from any machine

All four scripts work via `curl | bash` from any machine with network access to GitHub. Pick the URL flavour:

| Channel | URL pattern | When to use |
|---|---|---|
| **Stable (tagged)** | `https://raw.githubusercontent.com/rap77/aidlc-ops/<tag>/scripts/<script>.sh` | Production use; pins to a known release |
| **Bleeding edge (main)** | `https://raw.githubusercontent.com/rap77/aidlc-ops/main/scripts/<script>.sh` | Testing unreleased changes |

Examples with the latest stable tag (`v0.1.0`):

```bash
# Audit only — read-only, no install
curl -fsSL https://raw.githubusercontent.com/rap77/aidlc-ops/v0.1.0/scripts/aidlc-bootstrap.sh | bash

# End-to-end install on a fresh project
curl -fsSL https://raw.githubusercontent.com/rap77/aidlc-ops/v0.1.0/scripts/aidlc-bootstrap-kit.sh | bash -s -- --yes

# Copy the toggle to another project that already has AIDLC
curl -fsSL https://raw.githubusercontent.com/rap77/aidlc-ops/v0.1.0/scripts/install-aidlc-switch-harness.sh \
  | bash -s -- ~/projects/another-app
```

## Download a release tarball

Every tagged release ships a tarball with the four scripts, README, and `.gitignore`:

```bash
# Download
curl -fsSL -O https://github.com/rap77/aidlc-ops/releases/download/v0.1.0/aidlc-ops-v0.1.0.tar.gz

# Verify (sha256 published alongside)
curl -fsSL https://github.com/rap77/aidlc-ops/releases/download/v0.1.0/aidlc-ops-v0.1.0.tar.gz.sha256 | sha256sum -c -

# Extract
tar -xzf aidlc-ops-v0.1.0.tar.gz
cd aidlc-ops-v0.1.0
```

Browse all releases: https://github.com/rap77/aidlc-ops/releases

## Harness support

All scripts work with any AIDLC harness: `claude`, `opencode`, `codex`, `cursor`, `kiro`, `kiro-ide`, `copilot`. Default harness is `opencode`; override with `--harness NAME`.

## Requirements

- `bash` 4+ (uses associative arrays in `aidlc-bootstrap.sh`)
- `curl` (only for `--apply` mode of `aidlc-bootstrap-kit.sh`)
- `git` (project-level dependency of AIDLC itself)

The scripts do not require `aidlc` to be installed — `aidlc-bootstrap-kit.sh` handles that case.

## CI

Two GitHub Actions workflows live under `.github/workflows/`:

- **`shellcheck.yml`** — runs on every push to `main` and on pull requests. Three jobs:
  - `shellcheck` — `shellcheck -x` over every `scripts/*.sh` (uses `ludeeus/action-shellcheck@v2`, pinned to v0.11.0)
  - `bash-syntax` — `bash -n` over every script (catches syntax errors that shellcheck misses)
  - `install-into-tmp` — smoke test: creates a fake AIDLC project in `/tmp`, runs `install-aidlc-switch-harness.sh` against it, verifies the copy is executable and `bash -n` clean, and runs `--audit` to confirm the diagnostic path works on a minimal project
- **`release.yml`** — triggered by pushing a tag matching `v*`. Builds `aidlc-ops-<tag>.tar.gz`, computes sha256, creates a GitHub Release with both files as assets and auto-generated release notes.

To ship a new release:

```bash
git tag -a v0.2.0 -m "v0.2.0 — short description of the change"
git push origin main v0.2.0
# shellcheck runs on the tag push, then release.yml packages + publishes
```

## Contributing

PRs welcome. Before opening one:

1. Run `shellcheck -x scripts/*.sh` locally — CI enforces it
2. Run `bash -n scripts/*.sh` — CI enforces it
3. If you changed `aidlc-bootstrap.sh`, run `bash scripts/install-aidlc-switch-harness.sh /tmp/smoke-target && bash /tmp/smoke-target/scripts/aidlc-switch-harness.sh --audit` to confirm the end-to-end path still works

## License

MIT-0 (same as upstream AIDLC).

## Upstream

[awslabs/aidlc-workflows](https://github.com/awslabs/aidlc-workflows) — the AI-DLC methodology and engine. This repo is operations tooling built on top of it.
