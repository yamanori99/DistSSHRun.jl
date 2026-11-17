---
name: vm-environment
description: Cursor Cloud Agent VM tools (juliaup 1.13, pinned runic/jetls, shellcheck) and HOME/JULIA_DEPOT_PATH rules.
---

# VM environment

## Provided by the environment Build

- **Julia** — juliaup default channel **1.13**, plus **1.14** and **nightly** channels
- **Runic** — `runic` on PATH and `julia --project=@runic -m Runic`, both at `.github/runic-version`
- **JETLS** — `jetls` app at the date rev in `.github/actions/jetls-check/action.yml`
- **shellcheck** — for shell script review
- **gh** and git credentials for this repository

Installed by `.cursor/install.sh`, which calls `.github/install-agent-tools.sh` (fail closed on error).

## Health check

```bash
bash .github/install-agent-tools.sh
```

If this fails, stop and report. Do not install tools into temporary depots yourself unless the task explicitly uses `INSTALL_AGENT_TOOLS_DEPOT` for a scripted test.

## Not available

- Docker
- `sshd` for SSH E2E
- `gh run rerun` (integration token cannot rerun workflows)

## HOME and JULIA_DEPOT_PATH

Never `export HOME` or `JULIA_DEPOT_PATH` in the persistent agent shell; that breaks git/gh with `could not read Username`. Prefix single commands instead.

To recover after a mistake:

```bash
export HOME=/home/ubuntu
unset JULIA_DEPOT_PATH
```

## juliaup / app shims

If `jetls` or `runic` fails after a juliaup update:

```bash
JULIA_APPS_JULIA_CMD="$HOME/.juliaup/bin/julia" jetls version
```

Prefix `PATH="$HOME/.julia/bin:$PATH"` when app shims are missing from PATH.