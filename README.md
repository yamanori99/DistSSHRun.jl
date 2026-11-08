# DistSSHRun.jl

[English](README.md) | [日本語](README.ja.md)

<!-- markdownlint-disable MD013 -->
[![Test](https://img.shields.io/github/actions/workflow/status/yamanori99/DistSSHRun.jl/CI.yml?branch=main&style=flat-square&logo=githubactions&logoColor=white&label=Test)](https://github.com/yamanori99/DistSSHRun.jl/actions/workflows/CI.yml)
[![Codecov](https://img.shields.io/codecov/c/github/yamanori99/DistSSHRun.jl?style=flat-square&logo=codecov&logoColor=white)](https://codecov.io/gh/yamanori99/DistSSHRun.jl)
[![docs-stable](https://img.shields.io/badge/docs-stable-blue?style=flat-square&logo=gitbook&logoColor=white)](https://yamanori99.github.io/DistSSHRun.jl/stable/)
[![docs-dev](https://img.shields.io/badge/docs-dev-blue?style=flat-square&logo=gitbook&logoColor=white)](https://yamanori99.github.io/DistSSHRun.jl/dev/)
[![Julia 1.13+](https://img.shields.io/badge/Julia-1.13+-9558B2?style=flat-square&logo=julia&logoColor=white)](https://yamanori99.github.io/DistSSHKit.jl/stable/requirements/)
[![code style: runic](https://img.shields.io/badge/code_style-%E1%9A%B1%E1%9A%A2%E1%9A%BE%E1%9B%81%E1%9A%B2-black)](https://github.com/fredrikekre/Runic.jl)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
<!-- markdownlint-enable MD013 -->

DistSSHRun is one run on shared machines over SSH: `setup`, `up`,
`go`, `ride`, `drive`, `hostinfo`, `pool`, `demo`, and `progress`.
The command is `julia -m DistSSHRun`.
Supported on **macOS, Linux, and WSL2 Ubuntu** (not native Windows).

A path with no command is not `go`. `help`, `-h`, and `--help` print the
command list and exit 0. No arguments prints that list and exits 1.
`--version`, `-v`, and `-V` print the version. `help <command>` is that
command's `--help`.

The longer guide is the
[DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/stable/).

## Install

```julia
pkg> add DistSSHRun
```

Julia **1.13+**. Examples use `julia --project=. -m DistSSHRun` so the
job project is the one you select. `host1`, `host2`, `script.jl`,
`driver.jl`, `empty-dir`, `result-root`, and `demo-dir` stand for an
SSH config name, a file, or a directory. They are not created here.

`ssh` is required. `git` is required only for clone, sync, and pull.
Collect, go slot pull-back, ship, and `push_cache!` send bytes with
stdlib Tar over SSH. Collect, pull-back, and `push_cache!` need a remote
Julia (`--julia`, or auto-detect). `push_cache!` also needs that Julia
to load stdlib `Tar` and `SHA`.

Original mtimes are not kept. Pull-back `touch`es extracted files. Ship
does not `touch`. A non-executable file arrives as mode `0644`, and an
executable file as `0755`.

## A normal run

The usual order is host facts, then Julia channels, then one project
prepare path, then `go` or `drive`. `ride` is experimental. `pool` is
optional and is not the next step after `hostinfo`. Check, test, result
recovery, and delete are not required steps.

Shared flags on most commands: `-q` / `--quiet`, `--progress` (live
status; TTY default), `--verbose` (full detail; non-TTY default),
`-y` / `--yes`, `--version` / `-v`, `-h` / `--help`. Hosts can be
positional tokens, `--hosts` CSV, or `--hosts-file`. On `setup`, `up`,
`hostinfo`, and `pool`, a `:N` suffix is ignored.

### Host facts

`hostinfo` prints one row per host and does not start a job. A row has
reachability, OS, cores, RAM, `julia --version`, and the Julia path.
There is no cluster total and no worker-count estimate. Missing fields
are `-`. A reachable host with no Julia is still exit 0. A failed host
still gets a row; any failure makes the command exit 1. Rows go to
stdout, including under `--quiet`.

```bash
julia --project=. -m DistSSHRun hostinfo \
  --julia auto parent child:host1
```

`--hosts parent,child:host1` and `--hosts-file hosts.txt` are the same
list. `parent` is the machine you launched from. `child:host1` is
an SSH config name. There is no `--parent` flag.

### Cluster totals (`pool`, optional)

`pool` is a separate summary, not a required follow-up to `hostinfo`.
Both read `collect_host_facts`. `pool` adds the cores and RAM of
reachable hosts, then one health row per host (cores and RAM only, no
OS, Julia version, or Julia path). One unreachable listed host fails
the command. It does not recommend `parent:N` or `child:host1:N`.

```bash
julia --project=. -m DistSSHRun pool \
  --hosts parent,child:host1
```

### Julia channels (`up`)

`up` talks to juliaup. Verbs are `add`, `default`, `update`, and
`status`. Hosts may be `child:host1` or `parent`. `:N` is ignored.
`parent` is not a `setup` host.

`add` installs a channel. `default` switches the host default and asks
you to type `default` unless `-y` is set. The running process keeps its
current Julia until restart. `update` with no channel updates every
installed channel. `update <channel>` updates that channel. `status`
prints one line per host: channel, installed patch, and available
update. A worker line also compares that patch with the parent. The
parent line does not. That skew is not an error.

On a non-TTY, full detail is already the default, so a normal `status`
also prints the raw `juliaup status` lines (including the build
triplet) under that summary. `--verbose` is the same detail. It is not
a different report, and the examples do not pass it.

```bash
julia --project=. -m DistSSHRun up add 1.13 child:host1
julia --project=. -m DistSSHRun up default 1.13 -y parent
julia --project=. -m DistSSHRun up status parent child:host1
julia --project=. -m DistSSHRun up update child:host1
```

`update` is optional. `setup --juliaup` and `--juliaup-update` were
removed; use `up`.

### Where the project lands

`setup`, `go`, and `drive` share one default remote path:
`~/<parent-directory>/<project-directory>`, from the environment
directory that holds the Manifest. A project member below that
directory is that path plus the member's relative path. Pass
`--remote-path` to `setup`, or set `DISTRIBUTED_REMOTE_PROJECT_ROOT`
for the process, to aim at another tree.

`go` and `drive` have no `--remote-path` flag. They see only the
environment variable or the default. A `--remote-path` passed only to
`setup` is not remembered. Put the same absolute path on every later
command:

```bash
julia --project=. -m DistSSHRun setup --remote-root \
  --remote-path /absolute/job child:host1
DISTRIBUTED_REMOTE_PROJECT_ROOT=/absolute/job \
  julia --project=. -m DistSSHRun setup --ship-tree \
  child:host1
DISTRIBUTED_REMOTE_PROJECT_ROOT=/absolute/job \
  julia --project=. -m DistSSHRun setup --instantiate \
  child:host1
DISTRIBUTED_REMOTE_PROJECT_ROOT=/absolute/job \
  julia --project=. -m DistSSHRun go child:host1:1 script.jl
```

`--remote-root` is a mode. The path is a separate `--remote-path` and
must be absolute. The mode does not read `~` or
`DISTRIBUTED_REMOTE_PROJECT_ROOT` as the directory to create. It
creates that one directory (mode `700`; group and other write cleared)
when the parent already exists, and it asks you to type `remote-root`
unless `-y` is set. The SSH user must own it, and it must not be group
or world writable.

Ship does not create a missing root from `$HOME`. The tilde default is
not a legal `--remote-root` path. Use the default only when that
directory already exists, and do not pass `--remote-path`:

```bash
julia --project=. -m DistSSHRun setup --ship-tree child:host1
julia --project=. -m DistSSHRun setup --instantiate child:host1
julia --project=. -m DistSSHRun go child:host1:1 script.jl
```

After `--ship-tree`, the copy lives at
`<remote-root>/runs/<run_id>/src/`, with an empty `out/` and a
DistSSHRun `run.toml` (`schema`, `writer`, `kind`). Controller
provenance is `DISTSSHKIT_RUN_DIR/run.toml`, not that remote stamp.
`teardown` is DistSSHQueue, not this package.

If that remote root has no `Project.toml`, later `setup --instantiate`,
`setup --check`, `go`, and `drive` use the latest `runs/*/src` that has
one. If the root itself has `Project.toml`, that tree is the project
and `runs/*/src` is not selected. A clone and a ship snapshot under one
root are different sources. Pick one. `go` will not search for a path
you used only on an earlier `setup`.

### Prepare with a snapshot (`setup --ship-tree`)

`setup` is one command with one mode per run. Standalone
`setup --ship-tree` transfers the tree and stops. It does not
instantiate. The command prints the `src` path for the next
`--instantiate` or `--check`. There is no `ship` command.

`go --ship-tree` and `drive --ship-tree` are different: they extract
into `runs/<run_id>/src/` and instantiate hosts whose Manifest deps are
not already resolvable.

The ship root is the project directory, not a workspace Manifest above
it. Each directory's `.gitignore` applies (case-sensitive). No git
binary runs. `.git/info/exclude`, `core.excludesFile`, and a
`.gitignore` above the ship root are not used. A Manifest or path
dependency outside the directory is left out with a warning. A
gitignored `Project.toml`, `JuliaProject.toml`, `Manifest.toml`, or
`JuliaManifest.toml` is left out with one warning. A gitignored
`LocalPreferences.toml` is left out; add `!LocalPreferences.toml` to
ship it. Declared inputs are left out. A file over 50 MiB, or a send
list over 100 MiB, warns (`DISTSSHKIT_SHIP_WARN_FILE_BYTES`,
`DISTSSHKIT_SHIP_WARN_TOTAL_BYTES`; an invalid value is an error). The
256 MiB cap still stops the ship. `--allow-external-symlinks` keeps
symlinks that point outside the tree. `--rsync` was removed.

### Prepare with Git (`setup --clone`, then `--sync` or `--pull`)

`setup --clone` runs `git clone` on each remote into an empty path.
`--repo <url>` overrides `origin`. A path that already has files is
refused; `--delete` first if you mean to replace it. Credentials for a
private URL must exist on that host. Clone does not instantiate.

```bash
julia --project=. -m DistSSHRun setup --clone \
  --repo https://example.invalid/job.git child:host1
julia --project=. -m DistSSHRun setup --instantiate child:host1
```

Later updates are `--sync` or `--pull`, or `go --sync` / `drive --sync`.
None of these clone a missing tree. They need a clean committed local
tree and an existing clean remote Git tree. A dirty tree is refused and
is not sent as a patch. A shallow clone that lacks the commit is
refused and is not unshallowed.

`--sync` and `go --sync` / `drive --sync` first `git push` the local
branch to `origin` (every remote of that push, not only the listed
hosts). They then push that commit to `refs/distssh/<sha>` on each
listed host and `git checkout --detach` it. Submodules are updated
(`--init --recursive`). `git lfs pull` runs only when `.gitattributes`
asks for LFS. They do not run `git pull`. They do not instantiate.
`setup --pull` skips the `origin` push and still does the per-host ref
push and detached checkout. It also does not run `git pull`.

```bash
julia --project=. -m DistSSHRun setup --sync -y child:host1
julia --project=. -m DistSSHRun go --sync -y \
  child:host1:1 script.jl
```

`-y` skips the proceed prompt. It does not make a dirty tree acceptable.
`go --ship-tree` still instantiates; `go --sync` does not. Passing
`--sync` does not create the remote repository.

### Optional check and test

`setup --check` checks SSH, Julia, the project, and deps. It fails when
the Julia patch or prerelease differs from this process. A build suffix
alone still passes. `--ignore-julia-version` turns that skew into a
warning. `go` and `drive` compare the full `VERSION` string and the
Julia commit (`--allow-mismatch julia,distssh,manifest` waives named
fields). `setup --runtest` is `Pkg.test` of the job project on the
remotes. Neither command is required before `go` or `drive`.

```bash
julia --project=. -m DistSSHRun setup --check \
  --ignore-julia-version child:host1
julia --project=. -m DistSSHRun setup --runtest \
  --julia auto child:host1
```

`--requirements` reprints the `setup` help page. It is not another
deploy mode.

### Run with `go` or `drive`

`go` runs the script as-is, once per slot, and the slots start
together. `parent:N` and `child:host1:N` are full-script runs, not
Distributed workers. Omitting `:N` is an error unless `--repeat N`,
which spreads `N` runs across the listed hosts (`:N` is then a per-host
cap). `parent:0` skips the parent when children are listed. Remote
slots `cd` to the project root. Each slot pulls its directory back with
Tar into `script-dir/.distsshkit/go/stem_UTC/slot-name/`.
`--output-dir` is that batch root, with one directory per slot under
it. A non-empty `--output-dir` is an error.
`--skip-sync` and `--skip-git-guard` request no pre-run copy; that is
already the default.

```bash
julia --project=. -m DistSSHRun go \
  --output-dir empty-dir parent:1 child:host1:2 script.jl
julia --project=. -m DistSSHRun go --repeat 4 \
  child:host1 child:host2 script.jl
```

`drive` runs a Distributed driver, then collects. With no worker
tokens the parent count is 1. Omitting `:N` on a listed token is an
error. `-w <N>` / `--workers <N>` means `parent:N` when no parent token
is listed. `--sync-script` re-includes the full driver on workers; the
default sends definitions only. `--isolated` runs the driver in a child
process. `--require-git` opts into git parity, which is off by default
and stays off after `--ship-tree` (that tree has no remote `.git/`).
`--no-log` skips `drive_*.log`. `--log-dir` and `--package` name the
log directory and an explicit package. SSH workers use the project-root
cwd, bind `127.0.0.1`, and tunnel unless `DISTSSHKIT_SSH_TUNNEL=0`.

A normal `drive` collects by itself after `main()`. It does not need
`--collect-missing` or `--collect-overwrite`. Collection is files whose
mtime is newer than a sentinel placed in each collect root before
`main()`. Roots are `DISTRIBUTED_COLLECT_DIRS` (colon-separated) when
set, otherwise the drive output directory
(`{script}/.distsshkit/drive/stem_UTC/`, or `--output-dir`). Only
SSH hosts that took part are collected. `.git` paths are skipped. This
is not a copy of the whole project tree. `DISTRIBUTED_SKIP_COLLECT=1`
skips that pass.

`--require-all-hosts` is the default: every listed parent and child
must join, stay through the run, and collect. A host that does not join,
or that leaves during the run, stops the command before collection.
`--best-effort` allows a partial run.

```bash
julia --project=. -m DistSSHRun drive \
  --output-dir empty-dir parent:2 child:host1:4 driver.jl
```

`ride` is experimental. It splits `map`, `filter`, simple
comprehensions, and indexed `for` across Distributed workers, and it
rejects Distributed vocabulary (`drive` is that command). No tokens
means `parent:1`. An SSH child uses the same worker-add path as `drive`,
so the project must already be prepared. `ride` has no `--sync` or
`--ship-tree`. `--spi-check` compares with a sequential map/filter
(`--no-spi-check` leaves that off, which is the default).

```bash
julia --project=. -m DistSSHRun ride --spi-check \
  --output-dir empty-dir parent:1 child:host1:2 script.jl
```

### Phase times, not results (`progress`)

`progress` prints the last run's phase share of wall time from
`kit.progress`. It is not a live monitor and it does not fetch files.
The live line during a command is `--progress`. `-q` hides the time
table printed at the end of a run; `progress DIR` replays it.
`DIR` is an output directory, a `kit.progress` file, or a `*.log`
file. The default is the current directory. Extra arguments are an
error. An empty record exits 1.

```bash
julia --project=. -m DistSSHRun progress \
  script.jl/.distsshkit/drive/stem_UTC
```

### Retry a collect (`drive` only)

`--collect-missing` and `--collect-overwrite` do not run the script
again. They read the remote tree that already corresponds to local
`ROOT` and pull it to that directory. Flags go before the mode. `ROOT`
must not be the project or a parent of it.

Missing mode copies relative paths that are not already files under
`ROOT` and leaves existing files. Overwrite mode pulls the remote files
and replaces same-named local files. `.git` paths are skipped. Use these
after a run whose automatic collect did not finish, not as the normal
`drive` step.

```bash
julia --project=. -m DistSSHRun drive --collect-missing \
  result-root host1
julia --project=. -m DistSSHRun drive --collect-overwrite \
  result-root host1
```

### Maintenance

`setup --cleanup` kills stale Julia worker processes on localhost and
on each SSH host (`pkill -9 -f` for `julia.*--worker` and
`julia.*--bind-to`). It does not delete project files, and it does not
ask for confirmation. Local cleanup always runs. A remote counts as
failed only when SSH itself fails.

`setup --delete` and `setup --prune` are destructive. SSH does not
run until one of the two gates below has passed.

- `-y`, `--yes`, or `DISTSSHKIT_YES` with no `--confirm-path` exits 1.
  There is no prompt and nothing is deleted. Those switches do not
  stand in for the path.
- With neither `-y` nor `--confirm-path`, the command asks you to type
  `delete` or `prune` exactly. That keyword authorizes the delete.
  Any other answer, including an empty line, prints `Cancelled.` and
  exits 0.
- A `--confirm-path` that matches the computed target authorizes the
  delete without the keyword. `-y` does not relax a mismatch. A
  mismatch exits 1 and the message quotes the computed path. Quote a
  `~` path so the local shell does not expand it. One value is applied
  to every listed host. Do not paste a path out of
  `ConfirmPathMismatch` into a retry.

`help setup` summarizes these modes as needing `--confirm-path`. The
typed keyword above is still accepted when `-y` is absent.

The lines below are the flag shape. `PRINTED_PATH` is not a real path;
a value that is not the computed target exits 1.

```text
julia --project=. -m DistSSHRun setup --delete \
  --confirm-path PRINTED_PATH child:host1
julia --project=. -m DistSSHRun setup --prune \
  --confirm-path PRINTED_PATH --older-than DAYS \
  --id TOKEN child:host1
```

`--delete` removes the remote project tree. It refuses a present Ship
`run.toml` under the deploy root that this package does not own.
`--prune` removes `.distsshkit` go, drive, setup, and runs leaves on
the local project and on the remote path. It does not remove the
project tree. `--older-than` and `--id` apply only to `--prune`: age is
mtime in days, and `--id` keeps go / runs leaf names that contain the
token. The same ownership check applies to those candidates. A missing
older stamp still uses structural checks only.

`--remote-dir` was removed; the path flag is `--remote-path`.

### Demos and help

`demo list` prints demo ids and package paths. `demo install` copies
one family into `./distsshkit_demos/` (or `demo-dir/distsshkit_demos/`
with `--dest`). Families are `with_kit` (drive drivers), `without_kit`
(scripts for `julia` / `go`), and `ride`. Existing files are left in
place. `--force` overwrites those files. One install takes one family.

```bash
julia --project=. -m DistSSHRun demo list
julia --project=. -m DistSSHRun demo install with_kit \
  --dest demo-dir
julia --project=. -m DistSSHRun demo install ride --force
```

```bash
julia --project=. -m DistSSHRun help
julia --project=. -m DistSSHRun help go
julia --project=. -m DistSSHRun --version
```

## Remote shell

The login shell (`$SHELL`) must be POSIX (`sh`, `bash`, `dash`, or
`zsh`). `ssh host command` runs `$SHELL -c`, not a login shell.
Distributed starts workers with `sh -l -c`, and that wrap cannot be
changed. `fish` and `csh` are unsupported. An SSH name that starts with
`-`, including `user@-host`, is rejected. A host or remote path that
contains a control character is rejected.

## Documentation

- [Home](https://yamanori99.github.io/DistSSHRun.jl/stable/)
- [API](https://yamanori99.github.io/DistSSHRun.jl/stable/api/)
- [DistSSHKit](https://yamanori99.github.io/DistSSHKit.jl/stable/)
- Versioning and releases: [DistSSHKit manual, Releasing](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/releasing.md)

DistSSHRun `b568025c-2759-4ef1-8b14-17d00e2cd000`
