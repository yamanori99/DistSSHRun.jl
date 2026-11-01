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

Julia **1.13+**. Hosts need **`ssh`**. Collect, `collect!`, and go slot
pull-back use stdlib Tar over SSH. The remote Julia executable is `--julia`,
or auto-detect. Remote mtimes are not kept. A non-executable file arrives as
mode `0644`, and an executable file as `0755`. A symlink that points outside
the copied tree is refused. Cache pull still needs
**`rsync`**. Ship uses stdlib Tar over SSH. Git deploys also need **`git`**.

`setup --ship-tree`, `go --ship-tree`, and `drive --ship-tree` extract the
git file list into `<remote_root>/runs/<run_id>/src/` (`run_id` is UTC plus
6 hex). The same leaf also gets an empty
`<remote_root>/runs/<run_id>/out/`. A repeated host is refused. Later
`--instantiate` / `--check` / `go` use the latest `src/` when
the remote root has no `Project.toml` (or pass `--remote-path` to that tree).
`--rsync` was removed in 0.2.0. Workers `--project=` that tree.
`setup --remote-root --remote-path /absolute/path` creates that one
directory with mode `700`. Group and other write are cleared again after
`mkdir`. The parent must already exist. `~` and
`DISTRIBUTED_REMOTE_PROJECT_ROOT` are not a source for this command.
Confirmation is required unless `-y` is used.
The directory must be owned by the SSH user and must not be group-writable
or world-writable. No marker file is written, and `runs/` is not created.
Provenance and `run.toml` live on the controller under `DISTSSHKIT_RUN_DIR`
(`schema = 1`, `writer = "DistSSHRun x.y.z"`). They are not written into the
remote leaf. Unknown keys are ignored when reading. A ship that sees
`.distsshkit/inputs.toml` writes those inputs into this run's `run.toml`.
With hashing on, it also writes a manifest under `inputs/<sha256>.manifest`.
The file name is the SHA-256 of `ncodeunits(name):name`, a newline, and the
host. Each line is `hex *path`. A regular file is the SHA-256 of its bytes.
A symlink is the SHA-256 of its link text and is not followed.
`sha256sum -c` follows the symlink and normally reports `FAILED`; use
`check_input_manifest` to verify symlink rows. A declared path that is a
symlink to a file is recorded as that link, not as the target bytes.
A link target with a tab or newline is refused, including when the
declared path itself is a symlink. A path with a backslash is refused.
`check_input_manifest(manifest, root)` checks both and resolves each
path component by NFC form when the filesystem kept NFD. `sha256sum -c`
opens paths literally, so use `check_input_manifest` for those trees.
`hash = false` records only stat fields in `run.toml` and does not write
a manifest. A later ship into the same run directory replaces the row
for the same input name and host. Standalone `setup --ship-tree` waits
for hashing before it returns. `drive` / `go` with `--ship-tree` start
hashing after extract and finish it while instantiate, worker launch,
and precompile run. `outputs` is reserved and not written. There is no
`run.private.toml`; public records keep relative paths and aliases only.

`terminate!` and `terminate_run!` record how the stop ended. `KitRunResult.stop`
is `:within_grace` when the process exited after one SIGINT and before
SIGTERM, `:sigterm` or `:sigkill` when that `interrupt_grace` window ended
and the ladder escalated, and `:no_sigint` when `interrupt_grace` was 0.
`nothing` means this call did not run the ladder. The same string is `stop`
in `kit.result`. When the kit run directory already has this package's
`run.toml`, `stop` is set there too. `terminate_run!` finds that directory
from `kit.run_dir` next to `kit.pid`. A `run.toml` in the artifact
`output_dir` or log directory is left alone unless the supplied
`output_dir` already holds this package's `run.toml`; `terminate_run!`
updates that file. `schema` stays 1. Read it from
the return value or from `kit_result_from_dir` / `read_kit_run_toml`.

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
