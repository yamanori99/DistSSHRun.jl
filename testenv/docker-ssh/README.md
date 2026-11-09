# Docker SSH workers (CI E2E)

Real OpenSSH Linux workers. CI remote SSH coverage uses this stack
([`SSH E2E`](../../.github/workflows/CI.yml)). Optional Mac-only path
(same image and `test/e2e.jl`):
[`../apple-container-ssh`](../apple-container-ssh) — `./scripts/up.sh --e2e`
(Apple `container`; **not CI**). Do not run both stacks at once (shared
`ssh_config`).

## Coverage matrix

- Linux (`ubuntu-latest`), workers `ubuntu:26.04` ×2: **CI** — main /
  a version-cut PR (`E2E`) and weekly (`E2E weekly / DistSSHRun (ubuntu-latest → ubuntu-26.04)`)
- macOS Intel (`macos-15-intel` + Colima), same image: **E2E weekly** —
  `E2E weekly / macos-15-intel → ubuntu-26.04`
- WSL2 (`windows-latest`), same image: **E2E weekly** —
  `E2E weekly / windows-latest (WSL2) → ubuntu-26.04`
- Either kit parent, `parent:N`: mixed smoke inside the same suite

Suite inventory: [`test/README.md`](../../test/README.md#ssh-e2e).

### Honest limits

- CI macOS kit parent is **weekly / dispatch** (`macos-15-intel` +
  Colima). Apple Silicon GitHub runners cannot nest VMs.
- Remote Julia detection is exercised on **Linux workers**.
- **Not covered (no free CI):** Linux kit parent → macOS worker; Mac workers
  (local: [`apple-container-ssh`](../apple-container-ssh/README.md)
  `./scripts/up.sh --e2e`).
- **Git parity (`--require-git`):** covered via a separate git remote root
  (`git-clone` from a bare on child-1 → `git-sync` → `drive --require-git`).
  Mismatch before `git-sync` must fail. `git-pull` after a kit parent `git push`
  is checked by reading `e2e_sync_marker.txt` on the workers.

Worker image installs **two** juliaup channels from
[`.github/julia-slots.env`](../../.github/julia-slots.env):

- **default** = the stable line (today **1.13**) — matches the required E2E
  kit parent so `--check` runs **without** `--ignore-julia-version`.
  The 1.14-pre PR job sets `JULIA_DEFAULT_CHANNEL=1.14` so parent and
  workers start on 1.14; alt stays `JULIA_E2E_MISMATCH_CHANNEL` (1.12).
- **alt** = `JULIA_E2E_MISMATCH_CHANNEL` (today **1.12**) — a different
  major.minor so E2E can `juliaup default` to mismatch, then
  `up` to realign. Not a supported floor and not a Pkg.test slot.

The image also `Pkg.Registry.add("General")` on the default channel. A
fresh juliaup depot has no registries, and `setup instantiate` fail-closes
in that case (`no reachable package registries`). The registry lives in
`~/.julia/registries` and is shared by both channels.

`up.sh` passes both as Docker / `container` build-args and exports
`DISTSSHKIT_E2E_JULIA_{DEFAULT,ALT}_CHANNEL` for `test/e2e.jl`. On the build
path it also resolves each channel's current release from `versions.json`
(`JULIA_DEFAULT_RELEASE` / `JULIA_ALT_RELEASE`). That string is the image
cache key, so a new patch, or a prerelease becoming stable, rebuilds the
juliaup layer. The image build checks `julia --version` against it.
By default, `setup check` requires matching patch and prerelease versions
but ignores build suffixes. `go` and `drive` require matching `string(VERSION)`
and Julia commit unless `--allow-mismatch julia` is set. Install policy:
[Requirements](https://yamanori99.github.io/DistSSHKit.jl/stable/requirements/).
`--e2e` also runs
[`scripts/ensure-kit-parent-juliaup.sh`](scripts/ensure-kit-parent-juliaup.sh)
so the kit parent has juliaup + both channels (`up default` on parent;
CI `setup-julia` alone does not install juliaup).

On macOS, publish ports on `127.0.0.1` (Docker Desktop / Colima defaults)
so macOS 15 Local
Network Privacy does not block SSH from the kit parent.

## Layout

| Path | Role |
| --- | --- |
| [`Dockerfile`](Dockerfile) / [`start.sh`](start.sh) | Worker image |
| [`compose.yml`](compose.yml) | Two children (`child-1` / `child-2`) |
| [`scripts/julia-channels.sh`](scripts/julia-channels.sh) | slots → juliaup channel and release build-args |
| [`scripts/ensure-kit-parent-juliaup.sh`](scripts/ensure-kit-parent-juliaup.sh) | kit parent juliaup + channels for `--e2e` |
| [`scripts/gen-keys.sh`](scripts/gen-keys.sh) | Keys and SSH config |
| [`scripts/up.sh`](scripts/up.sh) | Keys → compose up → wait |
| [`scripts/wait-ready.sh`](scripts/wait-ready.sh) | SSH + Julia probe |
| [`scripts/prepare-manual-remote-root.sh`](scripts/prepare-manual-remote-root.sh) | Default `~/Parent/Repo` on workers (755) for manual ship |
| [`scripts/write-kit-env.sh`](scripts/write-kit-env.sh) | `.generated/env.sh` with absolute `-F` for DistSSHRun / git |
| [`scripts/with-env.sh`](scripts/with-env.sh) | One-shot command under that env (no parent export) |
| [`scripts/check-manual-smoke-quoting.sh`](scripts/check-manual-smoke-quoting.sh) | Quoting regression for env.sh / remote_root (`--live` optional) |
| [`scripts/down.sh`](scripts/down.sh) | Compose down |
| [`scripts/setup-colima-ci.sh`](scripts/setup-colima-ci.sh) | Colima CI |
| `.generated/` | gitignored SSH config / keys (created by scripts) |

SSH hosts (written to `.generated/ssh_config`):

- `child-1` → `127.0.0.1:2222` user `dev`
- `child-2` → `127.0.0.1:2223` user `dev`

## Local use (macOS, Linux, or WSL2)

Requires Docker Compose (Docker Desktop on Mac is fine; on WSL2, Docker must be
visible from the distro). Keep a WSL tree under `~/…`, not `/mnt/c/…`.

```bash
./scripts/up.sh --e2e    # workers + suite (always from kit root)
source ./scripts/up.sh   # workers + activate DistSSHRun SSH env in this shell
./scripts/down.sh
```

Skip the Julia-in-Docker build (macOS / WSL) by pulling the public image from
`main`'s last successful `E2E weekly`. If you changed `Dockerfile` /
`compose.yml`,
build locally instead (omit `DISTSSHKIT_WORKER_IMAGE`).

```bash
export DISTSSHKIT_WORKER_IMAGE=ghcr.io/yamanori99/\
distsshrun-linux-ssh-worker:latest
./scripts/up.sh --e2e
```

A local image build retries up to three times (`DISTSSHKIT_BUILD_RETRIES`,
default 3; waits 30 s, then 60 s). juliaup fetches its version list from
S3 after the installer download, and a short network failure there would
otherwise fail the run. Set `DISTSSHKIT_BUILD_RETRIES=1` while debugging
the Dockerfile. CI sets `DISTSSHKIT_BUILD_CACHE=gha`, which builds with
buildx and the GitHub Actions cache. The juliaup layer is reused until the
pinned Julia release changes, so most runs do not contact julialang-s3 during
the build.

On a Mac or in WSL2 this is how you cover that kit parent against Linux workers.
Suite coverage / artifacts: see `test/e2e.jl` and
`test/artifacts/README.md` (`$(cat test/artifacts/ssh-e2e/LATEST)/SUMMARY.txt`,
plus `JULIA_PATHS.txt`).

Manual smoke:

After workers are ready, `up.sh` always runs
`prepare-manual-remote-root.sh` then `write-kit-env.sh` (including when
you pass `--e2e`). That creates the DistSSHRun default remote root
(`~/Parent/RepoName`, mode 755) so manual `setup ship-tree` without
`--deploy-root` is not refused for group/world writable, and writes
`.generated/env.sh`. The E2E suite still uses `/home/dev/distsshkit-e2e`
and its own ensure helper; a failure in those prepare steps aborts `up`
before E2E starts.

```bash
# source (not ./) so DistSSHRun SSH env is loaded into this shell:
source ./scripts/up.sh
julia --project=../.. -m DistSSHRun \
  up status parent child:child-1 child:child-2 --verbose
# One-shot without sourcing the shell:
# ./scripts/with-env.sh julia --project=../.. -m DistSSHRun …
# Or plain ssh:
ssh -F .generated/ssh_config child-1 'echo ok; julia --version'
```

CI and `./scripts/up.sh --e2e` still run as a normal executable (no parent
export). Quoting checks: `./scripts/check-manual-smoke-quoting.sh`
(add `--live` when workers are up).

## CI

[`.github/workflows/CI.yml`](../../.github/workflows/CI.yml) runs
`./scripts/up.sh --e2e` on `ubuntu-latest` for **main** (E2E-relevant
paths), a PR whose `Project.toml` `version` went up, and manual dispatch
(`DistSSHRun (1.13, ubuntu-latest → ubuntu-26.04)` required;
`DistSSHRun (1.14-pre, ubuntu-latest → ubuntu-26.04)` continue-on-error). Other PRs run it only when those paths
change.
[`.github/workflows/ssh-e2e-weekly.yml`][e2e-weekly]
(`E2E weekly`) runs daily at 04:00 JST or via Run workflow: bake
`ubuntu-latest (image)` to GHCR, then `ubuntu-latest`, `macos-15-intel`, and
`windows-latest (WSL2)` pull that tag and run the suite. Scheduled Linux is the
same suite as a version-cut PR / **main** Linux E2E, not a PR check.
Register from the version-cut PR's Linux E2E. Intel / WSL are
watchers (`cut-hold` only if scheduled Linux is red).

Those kit parent jobs wait for `ubuntu-latest (image)` then pull
`ghcr.io/<owner>/distsshrun-linux-ssh-worker:<sha>` instead of building
Julia-in-Docker on Colima / WSL `dockerd`. Push to GHCR is retried until the
tag is inspectable (GHCR `unknown blob`). After the scheduled Linux suite,
`:latest`
is pushed for
local pull. The package is meant to be **public** (one-time: package Settings →
Change visibility). Local `./scripts/up.sh` still builds unless you set
`DISTSSHKIT_WORKER_IMAGE`. Colima on Intel runners uses `--cpu 3 --memory 8`
so the Darwin kit parent keeps RAM.

Usual `Pkg.test()` does **not** start Docker and does **not** run this suite.

[e2e-weekly]: ../../.github/workflows/ssh-e2e-weekly.yml
