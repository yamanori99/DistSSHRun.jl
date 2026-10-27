# Contributing

Internals of this repo.

- Users: [DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/stable/), [README.md](README.md), [README.ja.md](README.ja.md), [NEWS.md](NEWS.md)
- API docs: [dev](https://yamanori99.github.io/DistSSHRun.jl/dev/) ([docs/README.md](docs/README.md))

This is a **separate** package from DistSSHKit: FIFO `serve` in front of one Kit `go` / `ride` / `drive`, not a bigger Kit. Placement tokens, `execute!`, `kit.pid` / `kit.result`, `terminate_run!`, demo argv, and rsync/collect are Kit's. Queue records table state and the path Kit already wrote.

CI names Julia versions in the job (`1.13`, `1.14-nightly`, `nightly`), same as DistSSHKit. SSH E2E is this repo's `testenv/docker-ssh`. CI is `Pkg.test` (unit + integration), `Registry install (1.13, ubuntu-latest, x64)`, JETLS, Aqua, Linux SSH E2E on Julia **1.13** (`test/e2e.jl`: `setup` / `go` / `ride` / `drive`) on path-filtered PRs / **main** / a `Project.toml` version increase / weekly / dispatch, Gitleaks, light **Runic** `--check` (soft on PRs; monthly on `main`), schedule-only **E2E weekly** (Linux / macOS Intel / WSL), and schedule-only **CI weekly**.

## Requirements

macOS, Linux, or WSL2 Ubuntu. Not native Windows (the kit shells out to `ssh` / `rsync`).

| What | Need |
| --- | --- |
| Library, `Pkg.test()`, `julia -m DistSSHKit`, docs | Julia **1.13+** |
| DistSSHKit | **0.9.x** from General (`execute!`, `job_id`, `run_dir` / `kit.pid` / `kit.result`). Not a git sibling. |

Prefer [juliaup](https://github.com/JuliaLang/juliaup). Details: [Requirements](https://yamanori99.github.io/DistSSHKit.jl/stable/requirements/).

## Setup

```bash
git clone https://github.com/yamanori99/DistSSHRun.jl.git
cd DistSSHRun.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

The scripts under `src/cli/` do not instantiate this checkout.

That pulls DistSSHKit from General. Do not add a `[sources]` path to a Kit checkout unless you are landing an unreleased kit hook.

From another app (a **separate** env, not a job whose Manifest is copied to workers):

```bash
julia --project=/path/to/RunDevEnv.jl -e 'using Pkg; Pkg.develop(path="/path/to/DistSSHRun.jl")'
```

Do not `Pkg.develop` Queue or Kit from a project you actually run
distributed jobs from — the Manifest records an absolute path the
workers do not have. Keep a separate environment for package work.

## Test

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

Run this on Julia **1.13** (and **1.14-nightly** or **nightly** if you have them). Layout: [test/README.md](test/README.md). `test/runtests.jl` counts its `_runtest_announce` calls for `[i/N]`. `test/e2e.jl` counts its `_e2e_announce` calls the same way. Unset, that run includes every announced file. `DISTSSHRUN_TEST_SHORT=1` skips the heavy ones, and `JULIA_PKGEVAL=true` turns that skip on by itself.

Checkout `Pkg.test()` is not a registry install. General puts the committed tree in `~/.julia/packages/DistSSHRun/<slug>` with read-only files and no gitignored `Manifest.toml`. `lib/` is part of that tree. CI runs that install on the heavy gate (`Registry install (1.13, ubuntu-latest, x64)`), including ordinary pull requests and **main**. A pull request installs its head commit, not the merge commit. Dependencies come from General. The job sets `JULIA_PKGEVAL=true`, which selects the short file list. `PkgEval (nightly, ubuntu-latest, x64)` is the sandbox in [test/README.md](test/README.md#pkgeval). CI runs that job on ordinary PRs (heavy gate) and **main** (host Julia 1.13; test Julia is the julia-latest tarball; `continue-on-error`; not a required check). Run that recipe before a General cut.

```bash
julia -e 'using Pkg; Pkg.Apps.add("Runic")'   # once
runic --inplace src lib test docs testenv   # before push; not `.` (markdown out of scope)
./.github/jetls-check.sh    # hint+; same files as CI
./.github/aqua-check.sh     # latest registry Aqua; not part of Pkg.test()
./testenv/docker-ssh/scripts/up.sh --e2e
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs --color=yes docs/make.jl
gitleaks detect --source .
```

[Runic](https://github.com/fredrikekre/Runic.jl) CI
(`fredrikekre/runic-action@v1`, `version: '1'`) runs `--check` on every
tracked `.jl`. Format `docs/*.jl` and `testenv/**/*.jl` too if you change
them. A Runic minor may make `--check` red: re-run
`runic --inplace src lib test docs testenv` and push.
Optional: after a bulk format squash, add the landed SHA to
[`.git-blame-ignore-revs`](.git-blame-ignore-revs) if blame is noisy.
Local blame:

```bash
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

VS Code: recommend
[Custom Local Formatters](https://marketplace.visualstudio.com/items?itemName=jkillingsworth.custom-local-formatters)
(`.vscode/extensions.json`). User `settings.json` (do not commit):

```json
"customLocalFormatters.formatters": [
    {
      "command": "runic",
      "languages": ["julia"]
    }
]
```

JETLS CI uses [`.github/actions/jetls-check`](.github/actions/jetls-check/action.yml) (installs `JETLS.jl` `@release` after `julia-actions/cache`). After a bump, re-read [cli-check](https://aviatesk.github.io/JETLS.jl/dev/cli-check/) and keep failing on hint+.

JETLS is the type gate. Do not commit `.vscode/settings.json` to silence the Language Server.

[Fatou](https://fatou.dev) is local only. Do not add `fatou.toml` or Fatou to `.vscode/extensions.json`. After a Fatou bump, check it did not rewrite files you did not mean to touch.

### Julia versions

Workflows pass the version to `julia-actions/setup-julia`. The job name is that version.

| Version | Role | Required |
| --- | --- | --- |
| **1.13** | `Project.toml` julia floor. Pkg.test, Aqua, JETLS, Documenter, draw, E2E, Runic. Codecov `pkgtest` on **main push** only | yes |
| **1.14-nightly** | `release-1.14`. Pkg.test, Aqua, JETLS. `continue-on-error` | no |
| **nightly** | Published `julia-latest` tarball. It follows master and can lag a `VERSION` bump. Same jobs as 1.14-nightly. `continue-on-error` | no |

**1.13** runs on ordinary PRs (heavy gate), on Ubuntu and macOS.
WSL2 1.13 runs on a main push and CI weekly, not on a pull request.
**1.14-nightly** and **nightly** `Pkg.test` and Aqua on Ubuntu run on **main**,
**CI weekly**, and a `Project.toml` version increase
([`.github/version-cut.sh`](.github/version-cut.sh)), not ordinary PRs.
`JETLS (1.14-nightly, ubuntu-latest, x64)` uses the same heavy gate as the
1.13 JETLS job, including ordinary PRs. It is `continue-on-error` and is
not a required check.
macOS and WSL2 nightly `Pkg.test` and Aqua run on **CI weekly** only. `Registry install (1.13, ubuntu-latest, x64)` uses the same heavy gate as Ubuntu `Pkg.test` 1.13, including ordinary pull requests and **main**. It is not `continue-on-error`. PkgEval uses that same heavy gate and also runs on ordinary PRs. It stays `continue-on-error` and is not a required check.

This package feels SSH hosts, Pkg, and lockfiles more than a compute-model
library does. When Julia announces that it has stopped maintaining the
previous minor, raise the floor to the new stable. The move from 1.12 to
1.13 is that case (1.12 became unmaintained when 1.13 shipped). Do not
track the LTS for its own sake. Other situations (a prerelease as the
floor, dropping a minor only for a language feature, and similar) are
decided one by one. Do not move the floor to nightly, or to a minor that
has only just shipped, as an automatic rule.

When the floor moves, rename the **1.13** jobs to the new version in the same PR as `Project.toml`, the worker Dockerfile `--default-channel`, and the WSL `julia_channel`. Ruleset `main` uses those job names, so update the required checks with the rename.

JETLS stays on a runtime it lists (today 1.12.2–1.13). Raise that job's version only after JETLS supports it. No JETLS on nightly.

When a new RC of the floor's minor lands, point **1.13** jobs at `~1.13.0-0` so setup-julia includes prereleases. When that minor GAs, drop the tilde. A new **major.minor** is a floor move, not a second stable job.

### PR CI

These run as jobs of the `Test` workflow
([`.github/workflows/CI.yml`](.github/workflows/CI.yml)). Ubuntu:
`Pkg.test` 1.13, `Registry install (1.13, ubuntu-latest, x64)`, JETLS 1.13, Aqua 1.13, Gitleaks. macOS (`macos-latest`):
`Pkg.test` 1.13, same heavy gate, no coverage
upload. macOS runs `ps -o lstart=` in `kit_process_start_key`. macOS is
required. WSL2 1.13 is a main push and CI weekly, not a pull request.
Gitleaks also rejects `< 0.0.1` in `Project.toml`. Documenter 1.13 is
[`.github/workflows/Documentation.yml`](.github/workflows/Documentation.yml).
A pull request that runs it also pushes a preview to `gh-pages` at
`previews/PR<n>`. The commit status `documenter/deploy` links to
`https://yamanori99.github.io/DistSSHRun.jl/previews/PR<n>/`.
That directory stays after the pull request closes.
`Assets` (`draw SVG`) runs if `docs/src/assets/` or that workflow
changed. Linux E2E (1.13) uses the same **path filter** as **main** push
(`src/**`, `lib/**`, `test/**`, `testenv/**` minus markdown under those trees,
`Project.toml`, `test/Project.toml`, `.github/workflows/CI.yml`). It also
runs on a **version increase**, **E2E weekly** (`ssh-e2e-weekly.yml`; `CI.yml` has no
`schedule`), and `workflow_dispatch`. **1.14-nightly** and **nightly** `Pkg.test` / Aqua
on Ubuntu stay on **main**, **CI weekly**, and a version increase, not
ordinary PRs. macOS and WSL2 nightly stay on **CI weekly** only.
`Registry install (1.13, ubuntu-latest, x64)` uses the same heavy gate
as Ubuntu `Pkg.test` 1.13, so ordinary pull requests and **main** run it.
It installs the head commit into a job-local depot and runs `Pkg.test`
with `--check-bounds=yes`. `JULIA_PKGEVAL=true` selects the short file list.
PkgEval runs on ordinary PRs
(heavy gate) and **main**. It is `continue-on-error` and not a required
check.

[Runic](https://github.com/fredrikekre/Runic.jl) is a separate light
workflow ([`.github/workflows/runic.yml`](.github/workflows/runic.yml)).
It is not a substitute for `Pkg.test`. Soft on PRs (not in the
required-name list). Monthly cron on `main` opens Issue
`Runic monthly failed` (`alert`) when `--check` is red.

These files **alone** skip the heavy jobs (UI: skipping; Pkg.test on
Ubuntu and macOS, Registry install, plus JETLS / Aqua, do not start). Documenter
still runs when `docs/**`, README,
`src/**`, or `Project.toml` changed; otherwise it is skipped too.
Linux E2E is skipped on allowlisted markdown-only PRs (same skipping UI):

- `AGENTS.md`, `REVIEW.md`, `README.md`, `README.ja.md`,
  `CONTRIBUTING.md`, `NEWS.md`,
  `SECURITY.md`, `LICENSE`
- `.gitignore`, `.git-blame-ignore-revs`,
  `.github/pull_request_template.md`, `.coderabbit.yaml`
- `docs/**`, and markdown under `test/` / `testenv/`

A new root markdown file stays heavy until listed in
[`.github/actions/ci-heavy/action.yml`](.github/actions/ci-heavy/action.yml).
A `Project.toml` version increase skips none of this: Pkg.test (Ubuntu,
macOS), Registry install, JETLS, Aqua, Documenter, and Linux E2E all run (E2E
Codecov too). macOS and WSL SSH E2E stay on `E2E weekly`, not the PR.
Register when the required checks below are green. Intel / WSL weekly are
watchers, not the register gate.

CI uploads Codecov on **main push** only (Run `Pkg.test` on 1.13, plus Ubuntu `Pkg.test` of DistSSHBase and DistSSHUp, flag `pkgtest`). PR E2E does not upload; a version-increase PR and **E2E weekly** Linux upload flag `e2e`. Public repo + Codecov OIDC (`id-token: write`). Status checks are informational (`codecov.yml`). Local coverage:

```bash
julia --project=. -e 'using Pkg; Pkg.test(; coverage=true)'
DISTSSHQUEUE_CODE_COVERAGE=1 ./testenv/docker-ssh/scripts/up.sh --e2e
```

Required to merge (ruleset `main` uses these names, except `Registry install (1.13, ubuntu-latest, x64)`, which is not in the ruleset yet). **1.14-nightly** and **nightly** jobs are allow-failure. A job skipped by the heavy / E2E gate shows as skipping (not a green empty run). Ubuntu nightly `Pkg.test` and Aqua run on **main**, weekly, and a version increase, not ordinary PRs. macOS and WSL2 nightly run on CI weekly only. PkgEval runs on ordinary PRs (heavy gate) and is not in the list below. `Registry install (1.13, ubuntu-latest, x64)` is in the list below. This change does not edit the ruleset, so that name does not block merge until it is added there. E2E weekly and CI weekly are not required. Run's titles are `DistSSHRun (...)`, the same shape as DistSSHBase and DistSSHUp, plus `DistSSHRun (1.14-nightly, ubuntu-latest, x64)`, `DistSSHRun (nightly, ubuntu-latest, x64)`, `Aqua (nightly, ubuntu-latest, x64)`, `JETLS (1.14-nightly, ubuntu-latest, x64)`, and `PkgEval (nightly, ubuntu-latest, x64)`. DistSSHBase and DistSSHUp are their own jobs on Ubuntu and macOS, and their own Ubuntu SSH E2E rows. Their WSL2 titles run on a main push and CI weekly, not a pull request. Downstream is `Downstream (DistSSHQueue@main, 1.13)` and `Downstream (DistSSHKit@main, 1.13)`. `Downstream SSH E2E (DistSSHQueue, 1.13)` runs on a version-cut pull request, a push to `main`, and `workflow_dispatch`. Ordinary pull requests skip it. Names outside the list are not in the ruleset. The ruleset itself is edited on GitHub; this list is the names to add.

- `DistSSHRun (1.13, ubuntu-latest, x64)`
- `DistSSHRun (1.13, macos-latest, aarch64)`
- `Registry install (1.13, ubuntu-latest, x64)`
- `DistSSHBase (1.13, ubuntu-latest, x64)`
- `DistSSHBase (1.13, macos-latest, aarch64)`
- `DistSSHUp (1.13, ubuntu-latest, x64)`
- `DistSSHUp (1.13, macos-latest, aarch64)`
- `JETLS (1.13, ubuntu-latest, x64)`
- `Aqua (1.13, ubuntu-latest, x64)`
- `Documenter (1.13, ubuntu-latest, x64)`
- `Gitleaks`
- `DistSSHRun (ubuntu-latest → ubuntu-26.04)`
- `DistSSHBase (ubuntu-latest → ubuntu-26.04)`
- `DistSSHUp (ubuntu-latest → ubuntu-26.04)`
- `Downstream SSH E2E (DistSSHQueue, 1.13)`
- `PR label`

| When | Workflow | What |
| --- | --- | --- |
| Daily 04:00 JST, or Run workflow | `E2E weekly` | `ubuntu-latest`, `macos-15-intel`, WSL2 → `ubuntu-26.04`, plus the same three hosts for DistSSHBase and DistSSHUp. Linux job uploads E2E Codecov. Not a PR check. Failure opens (or comments on) Issue `E2E weekly failed`; a later all-green run closes it. A red **Linux** job on a scheduled run adds `cut-hold`, and a later green scheduled Linux removes it. Intel / WSL red does not. |
| Daily 06:00 JST, or Run workflow | `CI weekly` | Same 1.13 jobs as a main push of Test (Run, DistSSHBase, and DistSSHUp on Ubuntu, macOS, and WSL2, plus downstream DistSSHQueue and DistSSHKit; no coverage). A pull request does not run the WSL2 rows, plus JETLS and Aqua. 1.14-nightly and nightly `Pkg.test` run on Ubuntu, macOS, and WSL2; Aqua on macOS and WSL2 runs here only. `Compile bench` measures precompile, load, CLI wall time, `src/**/*.jl` size, and the host OS, arch, and CPU on 1.13, 1.14-nightly, and nightly. The page opens on 1.13. A solid line marks a `Project.toml` version change. On the 1.13 slot, a dash-dot line marks a Julia patch change. CI weekly runs it, and a **main** push that changes the measured tree runs it too (`src/`, `lib/`, the bench measure inputs, `Project.toml`, and the compile-bench action and workflow). A docs-only push does not. A second run of the same commit on the same UTC day keeps the first sample. A **main** run appends that sample to the `bench-data` branch. A render job then rebuilds the README and `bench.html`, and a main run publishes that page on GitHub Pages. A **main** push of `bench/compile/report.jl` or `bench/compile/charts.jl` rebuilds them and does not measure. A pull request that changes the file renders the history into the job summary and does not push. A command that exits nonzero is not recorded. It flags a host change, a 1.5x jump (and a 200 ms method that is new or doubled) but does not fail the run. Not a PR check. Catches 1.13 / Aqua / JETLS `@release` drift when nothing merged that day. Failure of the 1.13 jobs opens Issue `CI weekly failed` (`alert`); 1.14-nightly, nightly, and compile bench are omitted from that notify. `cache-gc` keeps one Actions cache per restore-key prefix. |
| 1st 10:00 JST, or Run workflow | `Runic` | `runic --check` on tracked `.jl` (`version: '1'`). Not a required PR check. Catches Runic minor drift when nothing formatted that month. Failure opens Issue `Runic monthly failed` (`alert`). |

## Pull requests

- Branch from `main`. Squash-merge only. Merged heads are deleted.
- One reviewable change per PR. Split unless `main` would be broken in between.
- Large plans: discuss in an issue first, then small PRs.
- The body is
  [`.github/pull_request_template.md`](.github/pull_request_template.md):
  what changed, what ran, what it can break, and how to undo it.
  [AGENTS.md](AGENTS.md) tells an agent how to fill that.
  [REVIEW.md](REVIEW.md) tells a reviewer what failure looks like here.
  The type label stays out of the body. CI applies it. See
  [DistSSHKit releasing](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/releasing.md).
- That split follows
  [How the Claude Code team does code review](https://claude.dev/blog/solving-code-review-at-anthropic/).

### CodeRabbit (experimental)

Open PRs may get an optional [CodeRabbit](https://docs.coderabbit.ai) pass.
Config is [`.coderabbit.yaml`](.coderabbit.yaml) on the **PR head** (not a
merge gate). JETLS / tests / e2e stay the gate. Treat inline comments as
hints; do not apply Autofix or generated tests unless you want that change.
`@coderabbitai pause` / `review` as needed. Settings will move as we learn
what is useful.

## Release

Versioning, when to cut, the dependency floor, and how to register are in
the DistSSHKit manual:
[Releasing](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/releasing.md)
and
[Packages](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/packages.md).

In short: a breaking change raises `x` in `0.x.y`, anything else raises
`y`. Label a breaking pull request `breaking`. Register on the merge
commit. Release notes are often shorter than the NEWS section. Do not lower
`version`. A version held by `cut-hold` is registered after the hold
lifts. Do not publish a later number in its place. If `Downstream SSH E2E
(DistSSHQueue, 1.13)` is red on a version-cut pull request, do not register
until the cause is known, and open a DistSSHQueue issue when the cause is
DistSSHQueue.

### When to cut

[Releasing](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/releasing.md#when-to-cut).

### DistSSHKit

Day-to-day users add DistSSHKit. This repository is the run. A behavior
change that Kit reexports lands here first. Kit freeze and cut rules:
[Releasing](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/releasing.md#when-to-cut).

## Issues

**Issues** (Bug / Enhancement forms only): `bug` or `enhancement`. The area dropdown is triage; add `area:*` if useful. Horizon (`when:*`) is **when**, not type or path: every open Issue gets exactly one of `when:current` / `when:next` / `when:later`. `julia-next` is optional and orthogonal: Julia tip / next stable Base or stdlib drift (keep `when:later` until that Julia is the package contract). This repo has no Discussions; usage questions that are not a bug or a committed feature can wait or be an Issue. Security: [SECURITY.md](SECURITY.md).

A failure of one run is a DistSSHRun bug. Open it here. DistSSHKit reexports this package; do not file the same defect on Kit unless the meta-package wiring is what broke. See [DistSSHKit](#distsshkit).

Every PR needs one type label (`bug` / `enhancement` / `breaking` / `chore`) when labels exist.

## Labels

```bash
./.github/gen-labeler.sh          # rewrite
./.github/gen-labeler.sh --check  # CI drift
```

Every tracked path must match some `area:*` glob (`gen-labeler.sh --check`). Globs are positive paths; do not add `!` excludes (labeler ORs them as "not this path" and tags unrelated files). Path labeler syncs only `area:*`. After `setLabels` it restores type / other non-area labels so a concurrent Type job is not wiped.

| Paths | Label |
| --- | --- |
| `src/**`, `demos/**`, `test/unit/**`, `test/integration/**`, package meta | `area:run` |
| Harness under `test/` (not `unit/` / `integration/`) and `testenv/**` | `area:test` |
| `docs/**` | `area:docs` |
| `README.md`, `README.ja.md`, `NEWS.md`, `CONTRIBUTING.md`, `SECURITY.md` | `area:project-docs` |
| `.github/**`, `codecov.yml`, `.coderabbit.yaml` | `area:ci` |

New product path: edit the script, regenerate, create the GitHub label.

Backfill every PR after a vocabulary change:

```bash
./.github/retag-pr-areas.sh           # dry-run
./.github/retag-pr-areas.sh --apply
```

### Type labels

Every PR needs one of `bug` / `enhancement` / `breaking` / `chore`. Dependabot skips the type check (`dependencies` only). Override with `gh pr edit N --add-label …`.

Weekly Dependabot covers `github-actions` and Julia registry deps.
Stdlib names are `ignore` in [`.github/dependabot.yml`](.github/dependabot.yml)
(`Dates`, `Pkg`, `TOML`, `Test`). A new
third-party `[deps]` entry is picked up with no YAML change; a new
stdlib must be added to that ignore list. Stdlib `[compat]` stays with
the Julia floor. The Julia updater otherwise appends `< 0.0.1` for the
pre-1.10 Pkg.test 0.0.0 sandbox; this package is 1.13 and does not need
that union (comma is or, not and). Scan /
`./.github/pkg-compat-check.sh` rejects that token.

CI infers, in order:

1. A unique type on a closing issue (`Fixes #N`)
2. Else the branch prefix: `feat/` → enhancement, `fix/` → bug, `breaking/` → breaking, `chore/` / `docs/` / `ci/` / `test/` → chore.
3. Else a Conventional Commit title: `fix:` → bug, `feat:` → enhancement, `!` before the colon → breaking, and `docs:` / `test:` / `ci:` / `chore:` → chore. `type(scope):` is accepted.
4. Else `chore` when the diff has no `src/`, `ext/`, or root `Project.toml`. Anything else fails until someone adds one of the four labels.

`fix/` plus `Fixes` an enhancement issue gets `enhancement`. `breaking` may sit next to the type label. After a cut, a human registers when the required checks are green (or holds with `cut-hold` if scheduled Linux is red); TagBot tags.

Ruleset `main` requires check `PR label` (workflow `Type`). Type labels (`bug` / `enhancement` / `breaking` / `chore`) and each `area:*` must exist (`gh label create` if missing). `when:*` and `julia-next` are Issues only (not a PR type). Labels adds `cut` when the version rises above the base. Removing it sticks until the next rise. CI still reads Project.toml, not the label.

Colors match DistSSHKit: type is "what", area is "where". Do not give each `area:*` its own hue.

| Kind | Color | Labels |
| --- | --- | --- |
| Type | red / green / yellow / dark red / purple / mint | `bug` `enhancement` `chore` `breaking` `dependencies` |
| Path area | teal `#bfdadc` | `area:run` `area:project-docs` |
| Documenter | blue `#0075ca` | `area:docs` (and leftover `docs`) |
| CI | black `#000000` | `area:ci` |
| Scheduled failure | orange `#ff4d00` | `alert` on bot Issues (`E2E weekly failed`, `CI weekly failed`, `Runic monthly failed`) |
| Hold | pale blue `#BFD4F2` | `cut-hold` on Issue `E2E weekly failed` after a red scheduled Linux job |
| Test harness | pale blue `#c5def5` | `area:test` |
| Horizon | orange `#fdba74` / violet `#c4b5fd` / slate `#94a3b8` | `when:current` `when:next` `when:later` |
| Julia next | Julia purple `#9558b2` | `julia-next` (Issues: tip / next-stable API; not a PR type) |

| `when:*` | Use |
| --- | --- |
| `when:current` | Bug on the ordinary path or lying CLI; patch promptly |
| `when:next` | Non-breaking (opt-in, docs, CI); ships when needed or after 2 weeks |
| `when:later` | Breaking milestone batch, or waits on upstream (e.g. julia-next) |

An issue on the open breaking milestone (`X.Y.0`, no due date) gets `when:later`. That milestone is the batch in [When to cut](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/releasing.md#when-to-cut).

## Language

`.jl` comments, docstrings, and errors: English. Install or Docs links: `docs/src`, [README.md](README.md), and [README.ja.md](README.ja.md). User-visible behavior: NEWS. Generative AI is allowed; you own the diff. Keep docs plain.
