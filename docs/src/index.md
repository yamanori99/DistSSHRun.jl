# DistSSHRun

DistSSHRun is one run on shared machines over SSH: `setup`, `go`,
`ride`, `drive`, `hostinfo`, `pool`, `demo`, and `progress`.
Supported on **macOS, Linux, and WSL2 Ubuntu** (not native Windows).

The command is `julia -m DistSSHRun`.

`pkg> app add DistSSHRun` still installs `distsshrun`. That command is
experimental. The binary is the Apps copy, not `--project=.`. Apps
fixes `JULIA_LOAD_PATH`, so `drive`, `hostinfo`, and `pool` still need
`julia -m DistSSHRun`. Worker processes (local and SSH) set
`JULIA_LOAD_PATH=@:@stdlib` and `--project=` of the job tree; they do not
see `@v#.#`. Local workers also put the parent project, then DistSSHRun's
package directory, on that path so `ride` can load DistSSHRun when the job
tree does not. Parent `LOAD_PATH` mutations do not otherwise affect workers.

Drive workers ping pid 1 on interval `DISTRIBUTED_HEARTBEAT_INTERVAL_SEC`
(default 30) and exit with status 75 if the master does not answer within
`DISTRIBUTED_HEARTBEAT_DEADLINE_SEC` (default the `:peer_silent` wait, 600
seconds). That deadline is also the longest the master may go without
yielding. A worker that itself does not yield for more than twice the
interval resets its last-success time so that stall is not treated as a
dead master. The monitor stays on the default thread. Run always evals its
own `DistSSHHeartbeat` source into `Main.DistSSHHeartbeat` on workers; it
does not `using` DistSSHRun from the job Manifest.

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
or auto-detect. Original mtimes are not kept. Pull-back `touch`es extracted
files. Ship does not `touch`; files keep the extract-time mtime. A
non-executable file arrives as mode `0644`, and an executable file as
`0755`. A symlink that points outside the copied tree is refused.
`push_cache!` uses stdlib Tar over SSH and needs a remote Julia executable
(`--julia`, or auto-detect) that can load stdlib `Tar` and `SHA`. Ship uses
stdlib Tar over SSH. Git `setup git-clone`, `setup git-sync`, and
`setup git-pull` also need **`git`**.

`setup ship-tree` walks the
ship root and applies each directory's `.gitignore` (case-sensitive).
`.git/info/exclude`, `core.excludesFile`, and a `.gitignore` above the
project directory are not used. No git binary is run. The tar root is that
project directory when every path dependency stays inside it. A relative
path dependency outside it, or a workspace member, is shipped under the
common ancestor so the relative path still resolves. The recorded project
path is `runs/<run_id>/src/` plus that relative directory. An absolute
`[sources]` path, or a layout that would root the tar at `$HOME` or `/`,
is an error. A parent `.gitignore` does not drop a declared path dependency.
Files that dependency's own `.gitignore` excludes are left out. A workspace
member also ships the workspace `Project.toml` and the shared Manifest.
Sibling workspace members are not walked. `--extra-file PATH` may be
repeated; this version accepts one file and a second is an error
(`more than one extra file is not yet supported`). `setup!`, `sync!`, and
`snapshot` take `extra_files::Vector{String}` with that same error. The file
is stored at `_distsshrun_external/<basename>` under the remote project. A
symlink is followed once: the archive name is the link name and the bytes
are the target. Siblings of that file are not sent. A gitignored `Project.toml`,
`JuliaProject.toml`, `Manifest.toml`, or `JuliaManifest.toml` is left out
with one warning. A gitignored `LocalPreferences.toml` is left out too;
add `!LocalPreferences.toml` to ship it. A file over 50 MiB, or a send list over
100 MiB, prints a warning (`DISTSSHKIT_SHIP_WARN_FILE_BYTES`,
`DISTSSHKIT_SHIP_WARN_TOTAL_BYTES`; an invalid value is an error). The 256 MiB
cap still stops the ship. Declared inputs are
left out. `ship_send_list(root)` is that path list for the directory it is
given. It is public and is not exported. `rsync_send_list` remains the git
list for git-clone, git-sync, and git-pull. Extract is into
`<remote_root>/runs/<run_id>/src/` (`run_id` is UTC plus 6 hex). The same leaf also gets an empty
`<remote_root>/runs/<run_id>/out/`. A repeated host is refused. A missing
`remote_root` is created when safe: a `~/…` layout may create components
under the remote home with mode `700`; an absolute path requires its parent
and creates only the final component (same rule as `setup remote-root`).
A symlink at the target, unsafe ownership or permissions, `/`, a single
directory under `/` (for example `/scratch`), a path with `.` or `..`, this
machine's home, and the remote home itself are refused. Existing ancestor
directory symlinks are followed; components this operation creates must not
be symlinks. Existing directories are not chmod'd. Transfer failure after
create leaves the safe directory. Run-time `sync=` on
`go!` / `drive!` / `pipeline!` / detached `execute!` is an error; deploy with
[`sync!`](@ref) / [`setup!`](@ref) or CLI `setup` first. Ship with
`setup!` / `setup ship-tree`, including one outside script as `extra_files`
/ `--extra-file`, then `execute!(…; snapshot=id)` or `go` / `drive --snapshot ID`
with that same local script. The remote command is
[`remote_script_path`](@ref DistSSHRun.remote_script_path) (`_distsshrun_external/<basename>` under the
selected project). The `go` / `drive` CLI does not take `--ship-tree`: run
`setup ship-tree`, then `setup instantiate`, then `go` / `drive` with
`--snapshot ID`.
Later `setup instantiate` / `setup check` / `go` / `drive` / `ride` select a
snapshot with `--snapshot ID` (or `snapshot=` on `setup!` / `go!` / `drive!` /
`ride!`), else the local `.distsshkit/last-snapshot.toml` written after a
successful ship, else a git checkout that has `Project.toml` at the deploy
root on every host. A successful delete / git-clone / git-sync / git-pull
clears that local record for the matching deploy root. `go` / `drive` do not
copy on run (`--git-sync` / `--ship-tree` were removed); deploy with
`setup git-sync` or `setup ship-tree` first. Do not run `setup git-sync` on
hosts that are running `go` / `drive` against the same deploy root. Lexical
latest `runs/*/src` is not used. An explicit
ID is validated on every host and never falls back. After extract, the remote
leaf `run.toml` records `complete = true` and the shipped `content_tree_hash`
(Git tree hash of the tar contents; transfer finished, not a fresh remote
re-hash). Selection requires DistSSHRun ownership, `complete = true`,
`algorithm = "git-sha1"`, and a 40-digit hex hash on every host. Incomplete
or legacy leaves are not selectable. Collect recovery with
`DISTSSHKIT_RUN_DIR` uses that execution's `provenance.shipped` instead of a
newer last-snapshot record. A recorded `content_tree_hash` there must match
the selected remote stamp. A local last-snapshot record without a matching
40-digit hash is not used. `setup check` still prints SSH diagnostics
when selection cannot probe, then fails closed if the snapshot is invalid. `--rsync` was removed in 0.2.0. Workers `--project=` that tree.
`snapshot(local_root)` builds that tar in a temporary directory and records
`content_tree_hash` (`git-sha1`). The caller deletes `snapshot_directory`.
After [`transfer_tree`](@ref), files under `<dest>/.distssh/` (for example
`shipped.toml`) are remote metadata and are **not** part of `content_tree_hash`;
any code that re-hashes an extracted tree must exclude `.distssh/`.
The tar is `snapshot_tar` (`ship.tar` in that directory). `snapshot` does not
read depot preferences. `ship(snapshot, hosts, remote_root)` sends that tar
and does not pack again or delete it. It refuses depot preferences, hashes
the tar again immediately before sending, and throws `ArgumentError` when
the hash differs or the tar is missing. `confirm` defaults to false, so a
library `ship` does not prompt. `record=false` does not keep the ship for
controller `run.toml` in this process. `setup ship-tree` still confirms
unless `-y` is used, and that path deletes its temporary directory.
`setup remote-root --deploy-root /absolute/path` creates that one
directory with mode `700`. Group and other write are cleared again after
`mkdir`. The parent must already exist. `~` and
`DISTRIBUTED_REMOTE_PROJECT_ROOT` are not a source for this command.
Confirmation is required unless `-y` is used.
The directory must be owned by the SSH user and must not be group-writable
or world-writable. No marker file is written, and `runs/` is not created.
Controller provenance lives under `DISTSSHKIT_RUN_DIR/run.toml`
(`schema = 1`, `writer = "DistSSHRun x.y.z"`). When the run that wrote
this file shipped a tree, `provenance.shipped` records `content_tree_hash`
(`git-sha1`) and `run_id` (the remote `runs/<run_id>/` leaf). An absent
or empty key means that ship was not recorded. `result_content_tree_hash`
and `result_remote_run_id` read those strings from a `DriveResult`,
`GoResult`, or `KitRunResult`. They also read a `:ship_tree` `SyncResult`
and a `ShipTreeResult`. A `SyncResult` from any other mode returns `nothing`
for both. `result_run_dir` reads
`DISTSSHKIT_RUN_DIR` from those results and from `KitProcess`. Each remote
`runs/<run_id>/` also gets a minimal `run.toml` with only `schema`,
`writer`, and `kind = "ship"` so `setup delete` can refuse a Ship leaf
that is not DistSSHRun-owned. That stamp is not controller provenance.
`setup prune` searches `.distsshkit` candidates and applies the same
ownership check there; it does not inspect those Ship leaves. Older leaves
without that file still use structural checks only. DistSSHQueue
`teardown` is a different command; it may reuse the same remote stamp later.
Unknown keys are ignored when reading. A ship that sees
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
for the same input name and host. Standalone `setup ship-tree` waits
for hashing before it returns. `go` / `drive` / `ride` do not copy on run;
hashing for a ship finishes under `setup ship-tree` before selection.
`outputs` is reserved and not written. There is no
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

`setup check` fails when the worker Julia patch or prerelease differs
from this process. A build suffix alone still passes.
`--ignore-julia-version` turns that skew into a warning. `go` and
`drive` compare the full VERSION string and the Julia commit. `up`
runs `juliaup update` even when the channel name already matches.

```bash
julia -m DistSSHRun setup check child:host1
julia -m DistSSHRun go SCRIPT.jl
julia -m DistSSHRun ride parent:2 SCRIPT.jl
julia -m DistSSHRun drive parent:2 SCRIPT.jl
julia -m DistSSHRun hostinfo parent
julia -m DistSSHRun pool
```

```julia
using DistSSHRun
go!("job.jl")
```

## Delete and prune

`setup delete` and `setup prune` remove a remote tree only when
`--confirm-path` is the path that command prints. `-y`, `--yes`, and
`DISTSSHKIT_YES` do not authorize those two modes. Without that flag and
without `-y`, the command still asks you to type `delete` or `prune`.

`delete` also refuses when a present `runs/<run_id>/run.toml` under the
deploy root is not DistSSHRun-owned, including a symlink `runs/` or a
symlink directly under `runs/`. The confirmed path may be a git-work-tree
ancestor of that deploy root; the stamp check still uses the deploy root.
`prune` uses the same ownership rule on `.distsshkit` candidates. A
missing stamp (older trees) still uses structural checks only.

From Julia, `setup!(session, :delete; confirm_path)` and `:prune` follow
the same rule. `session.yes` does not delete. One SSH host accepts a
`String`. More than one host needs a `Dict` whose keys are the configured
host aliases. A host with no key is left in place. An unknown key is an
error. A mismatch throws `ConfirmPathMismatch`. Do not copy the target out
of that error into a retry. See `help setup`. `teardown` is DistSSHQueue,
not this package.
