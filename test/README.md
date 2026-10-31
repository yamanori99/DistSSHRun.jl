# Tests

How this repo tests DistSSHRun. Maintainer checklist:
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Run

From the package root:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

That is `test/runtests.jl` (unit + integration), sequential `@testset`s,
`test/Project.toml`. Aqua is a separate CI job, not `Pkg.test()`.
Unset, all 56 files run. `DISTSSHRUN_TEST_SHORT=1` (`true`, `yes`, and `on`
too) skips the heavy files and the extra `ride!` cases. `JULIA_PKGEVAL=true`
does the same so a PkgEval run stays inside the 45 minute limit.
`Pkg.test()` on this checkout is not a registry install and is not the PkgEval sandbox. Job smokes pass
`-y`; real `ssh` / `git` spawn runs only when that binary is on `PATH`;
real SSH clusters stay in `e2e.jl`. Reproduce that sandbox:
[PkgEval](#pkgeval).

Real SSH:

```bash
testenv/docker-ssh/scripts/up.sh --e2e
```

Details:
[`testenv/docker-ssh/README.md`](../testenv/docker-ssh/README.md).
Inventory: [SSH E2E](#ssh-e2e) below.

## Layout

```text
test/
  runtests.jl     # Pkg.test() — unit + integration
  e2e.jl          # real OpenSSH; not Pkg.test()
  support.jl      # loads support/
  support/        # subprocess, staging, E2E helpers
  unit/           # in-process (no child julia, no addprocs)
  integration/    # child julia and/or local addprocs
  fixtures/       # small scripts copied into temp hosts
  Project.toml
```

`unit/` mirrors Run's own sources. DistSSHBase and DistSSHUp tests live with
those packages and run as their own `Pkg.test` (`lib/DistSSHBase`,
`lib/DistSSHUp`). SSH e2e for those packages is `lib/<pkg>/test/e2e.jl`
(`DISTSSHKIT_SSH_E2E=1` after `testenv/docker-ssh/scripts/up.sh`).
DistSSHRun's `test/runtests.jl` does not include them.

```text
lib/DistSSHBase/test/   # Pkg.test of DistSSHBase; e2e.jl is SSH only
lib/DistSSHUp/test/     # Pkg.test of DistSSHUp; e2e.jl is SSH only
unit/
  DistSSHRun/     # ↔ src/DistSSHRun/ (API, setup cores, argv)
    argv/         # ↔ DistSSHRun/argv/
    setup/        # ↔ DistSSHRun/setup/
  cli/            # ↔ src/cli/
    drive/, go/, setup/, size/
```

`integration/` is grouped by area (`DistSSHRun/`, `drive/`, `demos/`,
`setup/`, `go/`, `size/`).

## Layers

Green on one layer does not imply the others. `Pkg.test()` does not run
`e2e.jl`. Most of `Pkg.test()` wall time is integration. Child CLI uses
`julia -m DistSSHRun`.

- **JETLS** (~25 s): types / hints on entry files. Not runtime.
- **Aqua** (~5 s): ambiguities, exports, compat (latest registry Aqua).
  Not CLI / workers.
- **unit** (~45 s): parse, paths, fake setup, throws. Not child julia,
  `addprocs`, SSH.
- **integration** (~3 min): child CLI and/or **local** `addprocs`. Not
  real SSH / rsync. `integration/drive/interrupt_grace.jl` is a detached
  `drive` plus `terminate!`.
- **e2e** (~15–25 min): real SSH + rsync, two Linux workers; **PR** /
  **main** (path filter), a `Project.toml` version increase, weekly, or
  dispatch (Compose). Not markdown-only allowlisted PRs. Not local-only
  CLI wiring.
  `test/e2e.jl` prints `[i/N]` at the start of each inner `@testset`
  (SSH steps can sit silent for minutes otherwise). `N` is the number of
  `_e2e_announce` calls in that file.
- **e2e weekly** (10–50 min): same `e2e.jl` from Linux, macOS Intel, or
  WSL2 (not a PR check; starts when `Project.toml` `version` goes up on
  `main`; Intel / WSL are watchers). Register when the required checks
  are green.
  Not macOS workers.
- **doctests** (~5 s): `src/` docstring examples (Documenter, Julia 1.13).
  Not workers / SSH.

## Compile bench

`bench/compile/measure.jl` records precompile time, `using` time, CLI wall time, the size of `src/**/*.jl` (file count, physical lines, non-blank lines, bytes), and the host (OS name, arch, CPU). CI weekly runs it on Julia 1.13, 1.14-pre, and nightly, and so does a `main` push that changes the measured tree (`src/`, `lib/`, the bench measure inputs, `Project.toml`, and the compile-bench action and workflow). A docs-only push does not. A second run of the same commit on the same UTC day keeps the first sample. A `main` run appends the sample to the `bench-data` branch. A render job then rebuilds that branch's README and `bench.html` from the history already there, publishes the page on GitHub Pages, and so does a `main` push that changes `bench/compile/report.jl` or `bench/compile/charts.jl`. That push does not measure. A pull request that changes the file renders the history into the job summary and does not push. A command that exits nonzero stops the run before a sample is written. Every run uploads the sample as an artifact. A run that is not `main` does not push. A sample is flagged when, against the previous sample on the same Julia slot, the host OS or arch changes, package precompile grows by 1.5x and 0.5s, a command wall grows by 1.5x and 1s, or a method of at least 200 ms is new in the top 20 or doubles. The job is `continue-on-error` and does not fail the weekly notify.

```bash
./bench/compile/measure.sh --slot local --history /tmp/compile-bench-history
./bench/compile/render.sh --history /tmp/compile-bench-history --readme /tmp/compile-bench-README.md
```

## PkgEval

[PkgEval](https://github.com/JuliaCI/PkgEval.jl) provides the sandbox the
ecosystem daily uses. The sandbox is Debian bookworm without `tzdata`, with
`LANG=C.UTF-8`, a pipe for stdout, and a 45 minute test limit. Daily uses
the General tarball. This recipe mounts this checkout read-only, and
dependencies resolve from General, so an unreleased DistSSHQueue change is
not in the sandbox. This package:
<https://juliaci.github.io/NanosoldierReports/pkgeval_badges/D/DistSSHRun.html>
Latest ecosystem report:
<https://juliaci.github.io/NanosoldierReports/pkgeval_badges/report.html>
Run it on Linux with cgroup v2 and unprivileged user namespaces, before a
General cut. The host Julia is 1.13 or newer. PkgEval is not in General,
so this adds it from its repository. The tested Julia is the published
julia-latest tarball (`julia="nightly"`). It follows master and can lag a
`VERSION` bump. The ecosystem daily pins a master commit and enables
assertions, so its Julia is not this tarball.
CI: `Registry install (1.13, ubuntu-latest, x64)` on the heavy gate
(ordinary pull requests and **main**). It `Pkg.add`s the head commit
into a job-local depot and runs `Pkg.test` with `--check-bounds=yes`.
`JULIA_PKGEVAL=true` selects the short file list above. Dependencies
resolve from General. The installed tree includes `lib/`.
`PkgEval (nightly, ubuntu-latest, x64)` stays on ordinary PRs (heavy gate)
and **main** (`continue-on-error`; not a required check). The sandbox sets
`JULIA_PKGEVAL=true`, which selects the same short file list.

From this checkout:

```bash
julia -e '
  using Pkg
  Pkg.activate(temp=true)
  Pkg.add(url="https://github.com/JuliaCI/PkgEval.jl")
  using PkgEval
  config = Configuration(; julia="nightly")
  pkg = Package(; name="DistSSHRun", url="/package")
  result = PkgEval.evaluate_package(config, pkg; echo=true,
      mounts=Dict("/package:ro" => pwd()))
  exit(result.status == :test ? 0 : 1)
'
```

## SSH E2E

Two Linux workers. `DISTSSHKIT_SSH_E2E=1`. Kit parent OS matrix:
[`testenv/docker-ssh/README.md`](../testenv/docker-ssh/README.md). Apple
silicon without Compose:
[apple-container-ssh README](../testenv/apple-container-ssh/README.md)
(`./scripts/up.sh --e2e`).

Open logs with [`test/artifacts/README.md`](artifacts/README.md):

```bash
open "$(cat test/artifacts/ssh-e2e/LATEST)/SUMMARY.txt"
```

Coverage uploads on **main push** (`Pkg.test` on 1.13) and **E2E weekly** /
version-cut PR E2E (`DISTSSHKIT_CODE_COVERAGE=1` on `up.sh --e2e`).
Path-filtered PR E2E runs without that upload. Local:

```bash
DISTSSHKIT_CODE_COVERAGE=1 \
  testenv/docker-ssh/scripts/up.sh --e2e
```

### Setup (ship-tree)

- Julia resolve: kit parent and remotes share major.minor
- `run_on_host`: `--version` exit 0; `-e exit(3)` is `.exitcode == 3`
  (no throw)
- `--delete`: remote `Project.toml` is gone
- `--ship-tree`: remote `runs/<run_id>/src/Project.toml` exists
- `--instantiate` / `--check`: job deps; Julia version (no
  `--ignore-julia-version`)
- `up`: remotes (mismatch → align); `parent` + one remote
  (kit parent + child default restored in `finally`). `--e2e` ensures
  kit-parent juliaup + both channels via
  `ensure-kit-parent-juliaup.sh` (needed on CI `setup-julia`)
- `--runtest`: job `Pkg.test` pass; a planted failure is non-zero
- `--ship-tree` onto an existing root: a new `run_id` leaf
- `~/…` remote path: delete → ship-tree → instantiate → drive still run

### Drive / go / size

`square_file` writes the CSV in `main()` on the **kit parent**. Workers
only return numbers. Collect tests use files workers write.

- `size`: both hosts, `GB`, `Total:`
- `square_echo`: remote compute; stdout has `param^2:`
- `square_file`: local CSV exists; absent on the remote
- `worker_*.txt`: on the worker; `run_on_host` read;
  `--collect-missing` restores; skip keeps junk;
  `--collect-overwrite` replaces; `kit.result` `hosts` names both
  remotes
- `kit.progress`: `kit_progress_latest` last event is `done` after demo
  drive / go
- worker `error(...)`: non-zero
- mixed `parent:1` + two remotes: smoke `nw=3`
- in-process `drive!` twice (reentrant): each call `nw=2`; no worker
  leak (#144)
- detached drive SIGKILL: wait until heartbeat monitors start, then
  remote `--worker` gone (#148)
- detached SSH ride `terminate!`: `kit.hosts` then remote `--worker` gone
- `go pi_echo`: π on both hosts
- `go --ship-tree` empty dedicated root: no prior `--instantiate`; π on
  both; remote `runs/<run_id>/src/Project.toml` appears
- `go pi_file`: slot `pi_results.txt` after go collect;
  `DISTSSHKIT_JOB_ID` set so remote `-L` mark is collected
- `go --output-dir`: `pi_results.txt` under the given batch root
- API: `setup!` / `go!(output_dir=)` / `pipeline!(collect=true)` on
  worker files

### Git (separate remote root)

- `--clone` / `--instantiate` / `--check`: remote hash matches
- `--require-git` after a local bump: fails
- `--sync` then `--require-git`: pass
- `--pull` after kit parent `git push`: `e2e_sync_marker.txt` on the
  workers matches

Child-1 can SSH to child-2 (compose DNS).

Not this file: macOS workers, dead hosts, fake `ssh`/`rsync`, local
`with_kit` recipes (`test/integration/demos/`).

## Fakes vs real SSH

- **setup:** core work is `ssh` / `rsync`. `Pkg.test()` uses fixtures
  `DISTSSHKIT_TEST_SSH` / `_RSYNC`, and only when `DISTSSHKIT_TEST=1`.
  Bytes on a real remote: e2e.
- **drive / go:** core work is `Distributed` workers. `Pkg.test()` uses
  real **local** `addprocs` (no SSH fake). Bytes on a real remote: e2e.
- **drive collect:** core work is `ssh` and stdlib Tar of result trees.
  Remote mtimes are not kept. File modes are not kept (`0644`, or `0755`
  if executable). An escaping symlink is refused. Remote Julia is `--julia`
  or auto-detect.
  Cache pull is still rsync. Bytes on a real remote: e2e.
- **size:** plan math (+ optional RSS). `Pkg.test()` is unit + local
  probe in `integration/size/`. Bytes on a real remote: e2e if needed.

Do not fake Julia SSH worker launch. Local workers stand in for drive/go;
they cannot stand in for setup. `_run_kit_setup` / `_run_kit_go` use an
ephemeral project unless `project_root` is set (E2E uses
`test/artifacts/ssh-e2e/`).

## Host tokens vs SSH names

Tests follow the same two surfaces as the kit. No extra test harness:

- CLI (`setup` / `go` / `drive` / `size`), `KitSession(workers=…)`, and
  hosts files use placement tokens (`parent:2`, `child:host-a:4`).
  setup / size ignore `:N`; `up` accepts `parent`
- Internal SSH names stay bare (`host-a`): `session.hosts`,
  `HostRunResult.host`, collect-only `HOST`, and fake SSH trees
- `_sample_hosts_file` / `_sample_setup_hosts_file` are placement tokens
  (`child:…`)

Do not search-replace a host name into a token (that produced
`child:child:…` and collect dirs named `child:host1`).

## Writing tests

1. Add under `unit/` (src mirror) or `integration/<area>/`.
2. Top-level `include` in `runtests.jl` (JETLS follows that). Do not
   register `e2e.jl` there (`Pkg.test` must not SSH). `e2e.jl` is its own
   JETLS entry in `.github/jetls-check.sh`.
3. Subprocess helpers in `support/`; one-off scripts in `fixtures/`.
4. Short Oracle / non-guarantee comment at the top of the file.
5. Pin verbosity with `with_kit_verbosity` if you assert kit detail
   lines. `Pkg.test` defaults to `:progress`. `kit_confirm` and consent
   warnings must show in `:quiet`, `:progress`, and `:verbose`.

Helpers (via `support.jl`): `_child_julia_env`, `_run_kit_drive` /
`_run_kit_setup` / `_run_kit_go` / `_run_kit_size`, `_mktemp_host` /
`_with_tempdir` / `_stage_with_kit_demos!`, `_with_ssh_e2e_suite`,
`_capture_stdio` / `with_kit_verbosity`.

- `DISTSSHKIT_SKIP_GLOBAL_WORKER_PKILL` (default `1` in test children):
  skip drive leftover tagged remote `pkill`; each child `rmprocs`es its own
  local workers. Untagged sweep is `setup --cleanup` only.
- `DISTSSHKIT_SSH_E2E` (unset): `1` runs `test/e2e.jl` (needs docker-ssh
  workers)
- `DISTSSHKIT_CODE_COVERAGE` (unset): `1` with `up.sh --e2e` →
  `--code-coverage=user`

CLI also honors `DISTSSHKIT_QUIET`, `DISTSSHKIT_PROGRESS`,
`DISTSSHKIT_VERBOSE`, `DISTSSHKIT_YES`, `DISTSSHKIT_HOSTS`,
`DISTSSHKIT_HOSTS_FILE` (`src/DistSSHRun/argv/session.jl`).

## Aqua

CI and [`.github/aqua-check.sh`](../.github/aqua-check.sh) `Pkg.add("Aqua")`
with no version pin. `Pkg` is a module dep (`using Pkg` in
`src/DistSSHRun.jl`) so Aqua `stale_deps` can run.
