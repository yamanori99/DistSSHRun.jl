# DistSSHRun

DistSSHRun is one run on shared machines over SSH: `setup`, `go`,
`ride`, `drive`, `plan`, `size`, `pool`, `demo`, and `progress`.
Supported on **macOS, Linux, and WSL2 Ubuntu** (not native Windows).

The command is `julia -m DistSSHRun`.

`pkg> app add DistSSHRun` still installs `distsshrun`. That command is
experimental. The binary is the Apps copy, not `--project=.`. Apps
fixes `JULIA_LOAD_PATH`, so `drive`, `size`, and `pool` still need
`julia -m DistSSHRun`. Worker processes (local and SSH) set
`JULIA_LOAD_PATH=@:@stdlib` and `--project=` of the job tree; they do not
see `@v#.#`. Local workers also put the parent project, then DistSSHRun's
package directory, on that path so `ride` can load DistSSHRun when the job
tree does not. Parent `LOAD_PATH` mutations do not otherwise affect workers.

DistSSHKit does not install a terminal command. When that package is
installed, `julia -m DistSSHKit` is the same entry.

The longer guide is the
[DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/stable/).

## Install

```julia
pkg> add DistSSHRun
```

Julia **1.13+**. Hosts need **`ssh`**. Collect and cache pull still need
**`rsync`**. Ship uses stdlib Tar over SSH. Git deploys also need **`git`**.

`setup --ship-tree`, `go --ship-tree`, and `drive --ship-tree` extract the
git file list into `<remote_root>/runs/<run_id>/src/` (`run_id` is UTC plus
6 hex). Later `--instantiate` / `--check` / `go` use the latest `src/` when
the remote root has no `Project.toml` (or pass `--remote-path` to that tree).
`--rsync` was removed in 0.2.0. Workers `--project=` that tree.
Provenance and `run.toml` use `schema = 1` and `writer = "DistSSHRun x.y.z"`.
Unknown keys are ignored when reading. `[[inputs]]` / `outputs` are reserved
and not written.

`terminate!` and `terminate_run!` record how the stop ended. `KitRunResult.stop`
is `:within_grace` when the process exited after one SIGINT and before
SIGTERM, `:sigterm` or `:sigkill` when that `interrupt_grace` window ended
and the ladder escalated, and `:no_sigint` when `interrupt_grace` was 0.
`nothing` means this call did not run the ladder. The same string is `stop`
in `kit.result` and in `run.toml` when that file already exists. `schema`
stays 1. Read it from the return value or from `kit_result_from_dir` /
`read_kit_run_toml`.

The remote login shell (`$SHELL`) must be POSIX-compatible (`sh`, `bash`,
`dash`, or `zsh`). `ssh host command` runs that shell as `$SHELL -c`, not
as a login shell. Distributed's `SSHManager` starts workers with `sh -l -c`,
and that wrap cannot be changed. `fish` and `csh` are unsupported. `fish`
can silently change quoting (a backslash inside single quotes). An SSH
name that starts with `-`, including `user@-host`, is rejected. A host or
remote path that contains a control character (NUL, newline, or any other)
is rejected. See `julia -m DistSSHRun help setup`.

## Commands

```bash
julia -m DistSSHRun setup --check child:host1
julia -m DistSSHRun go SCRIPT.jl
julia -m DistSSHRun ride parent:2 SCRIPT.jl
julia -m DistSSHRun drive parent:2 SCRIPT.jl
julia -m DistSSHRun plan SCRIPT.jl
julia -m DistSSHRun size
julia -m DistSSHRun pool
```

```julia
using DistSSHRun
go!("job.jl")
```

## Delete and prune

`setup --delete` and `setup --prune` remove a remote tree only when
`--confirm-path` is the path that command prints. `-y`, `--yes`, and
`DISTSSHKIT_YES` do not authorize those two modes. Without that flag and
without `-y`, the command still asks you to type `delete` or `prune`.

From Julia, `setup!(session, :delete; confirm_path)` and `:prune` follow
the same rule. `session.yes` does not delete. One SSH host accepts a
`String`. More than one host needs a `Dict` whose keys are the configured
host aliases. A host with no key is left in place. An unknown key is an
error. A mismatch throws `ConfirmPathMismatch`. Do not copy the target out
of that error into a retry. See `help setup`.
