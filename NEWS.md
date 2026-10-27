# News

User-facing changes.
GitHub Releases use the notes on `@JuliaRegistrator register`.
Those notes are often shorter than the section below.

## Unreleased

- `setup` exits 1 when more than one mode flag is passed. The message names those two flags and `help setup`, and parsing stops at the second flag. `plan`, `pool`, and `size` exit 1 on an unknown `-` option before any other argument is applied, including when `-h` or `--help` is also present. The message names that option and `help plan`, `help pool`, or `help size`. `-h` and `--help` still print help when every flag is known. `setup` already rejected an unknown option; that message now names `help setup`.
- The first `drive` in a process compiles less. `plan` is no longer inferred inside `run_drive_parsed!`, a drive without `--sync` or `--rsync` does not infer that path, and that call is precompiled. The text and the exit code do not change. Loading the package from a project still needs that project's dependencies instantiated.
- A CLI script from a checkout with no manifest exits with an instantiate hint and writes nothing under the depot. `julia -m DistSSHRun` and an installed package are unchanged.

### Breaking

- `drive` and `collect!` refuse a collect root that is the project root or a parent of it. That includes `DISTRIBUTED_COLLECT_DIRS=.` and a default root from `DISTRIBUTED_OUTPUT_DIR`. Point collect at a result directory inside the project. 0.1.7 warned and still collected. The check runs when sentinels are placed and again in `collect!` / `drive --collect-missing` / `drive --collect-overwrite`.

### Planned breaking (next minor)

- `interrupt_grace` on `terminate!` and `terminate_run!` will default to a positive value, so a stop sends SIGINT before SIGTERM. DistSSHQueue `cancel` of a running job will use that default. Until then the default is `0` and `cancel` does not send SIGINT.
- `setup --rsync` and `setup --sync` will refuse a `Manifest.toml` that would not ship, and git sync will refuse a path source whose `*.jl` or project files are ignored or untracked. 0.1.7 warns.
- `setup --sync`, `setup --pull`, and `sync!` will fail when the remote `HEAD` is not the local `HEAD`, including an unpushed local commit on `--pull`. 0.1.7 warns. A hash that could not be read stays a warning.
- `-y`, `--yes`, and `DISTSSHKIT_YES` will stop authorizing `setup --delete` and `setup --prune`. Without `--confirm-path`, `-y` will exit 1. With neither, the commands still ask for `delete` or `prune`. A matching `--confirm-path` still deletes.
- Display helpers that no package outside DistSSHRun calls will stop being exported. `parse_go_args`, `parse_drive_args`, and `parse_ride_args` stay exported. DistSSHKit 0.11 drops the names this package stops exporting.

## 0.1.16

- `unknown_subcommand_message`, `no_command_message`, `print_rejected_command`, `NO_COMMAND_HINT_LINES`, and `RUN_SUBCOMMAND_EXPECTATION` are public. They are the sentences an unknown `julia -m DistSSHRun` command already prints. The text and the exit code do not change. DistSSHKit calls these names.

## 0.1.15

- `help <command>` prints the same page as `<command> --help` and exits 0. `help`, `-h`, and `--help` with no command stay as they are. A second word that is not a command still exits 1, and the message names that word, except an argv made only of `help`, `-h`, and `--help`. Hints for a missing `size` or `pool` host say `help size` and `help pool`.
- An argv made only of `help`, `-h`, and `--help` prints the root page on stderr and exits 0. That includes `help --help`. `help bogus` still exits 1 and names `bogus`. `help go --help` is still the `go` page.

## 0.1.14

- `setup!(session, :check)` returns the warnings it printed in `SyncResult.warnings` as `SetupWarning` values. The output and the exit code do not change.

## 0.1.13

- `setup!(session, :rsync; gitignore = false)` sends the tree without applying `.gitignore`. `.git/` and `.distsshkit/` stay excluded. The default remains `gitignore = true`.
- `setup --check` warns when the same major.minor.patch has a different prerelease. The check still succeeds. `--ignore-julia-version` does not hide that warning, or a patch warning. A moving channel (`1.13`, `1.14-nightly`) still says the parent is behind a newer remote. A pinned channel such as `1.14.0-alpha1` says that channel may not be installed, and to check `juliaup add` on the worker. The success count is unchanged. `parse_julia_version` and `get_remote_julia_version` stay major.minor.patch. `parse_julia_version_full` and `get_remote_julia_version_full` are public on DistSSHBase.
- `run.toml` records `[provenance]` (Julia, machine, workers, the project manifest, and the code version). The same table is written to `output_dir/.distsshkit/provenance.toml`. For `go`, `julia.parent` is the controller; each slot is under `workers`, and a slot's own snapshot is `slot/.distsshkit/provenance-slot.toml`. A remote slot copies that file only when collect does not bring the slot directory. The manifest hash and the git snapshot are taken when the run starts. `.distsshkit/` and `.distsshqueue/` are not counted as uncommitted changes. `git_source_snapshot` is that git record, and the name is public. `schema` stays 1.
- `run.toml` `[provenance]` records `julia.install` as the nearest parent directory of `Sys.BINDIR` whose name starts with `julia-`. On macOS, `basename(dirname(Sys.BINDIR))` is `julia` for a release build and for a `+opt` build, so that name is not used. Processes with the same `version` and `commit` and a different `install` stay in different groups. When no `julia-*` parent exists, the key is omitted. `schema` stays 1.

## 0.1.12

- `DistSSHBase.wait_seconds(name, default)` resolves a named wait. DistSSHBase does not pick the seconds. `:until_exit` is `Inf`. `DISTSSHKIT_WAIT_<NAME>` overrides a finite name when it is a finite number ≥ 0. `DISTSSHKIT_WAIT_SCALE` multiplies only `:child_reply`, `:go_job`, and `:drive_job`. SSH `ConnectTimeout` and `ServerAlive`, and the worker heartbeat deadline, use this. Defaults stay 10 seconds to connect and about 600 seconds of silence. A positive SSH budget below 1 second becomes 1 second, and a non-positive one stays at that default, so `ConnectTimeout=0` does not replace the 10 second connect. A heartbeat deadline that is not positive stays 600 seconds, including when `DISTSSHKIT_WAIT_PEER_SILENT` is `0`. `DISTRIBUTED_HEARTBEAT_DEADLINE_SEC` still wins when it is positive. The name is public on DistSSHBase and is not exported from DistSSHRun.

## 0.1.11

- `up` and `setup --juliaup` ask juliaup for `X.Y-nightly` when this Julia is `X.Y.0-DEV`, and for the prerelease name otherwise (`1.13.0-rc1`). A release build still asks for `X.Y`.

## 0.1.10

- A failed or interrupted `go` slot appends `last top-level: path:line` when its log contains a Julia `eval:` trace. Set `Base.TRACE_EVAL = :loc` in the script. There is no new flag.
- `terminate!` and `terminate_run!` take `interrupt_grace` (default `0`). The default does not send SIGINT, so the stop sequence is unchanged. A positive value sends SIGINT and waits before SIGTERM.
- Ctrl-C during `drive` sends one `kill -INT` per SSH host, then waits a few seconds so a worker can `catch` `InterruptException` before `rmprocs`. A `ride` whose workers have already joined does the same when that run fails or is interrupted. A `ride` that fails while workers are still joining removes those workers without that signal. On Julia 1.13, Ctrl-C while `drive` waits in `pmap` does not run this path. The driver exits 1 and does not send `kill -INT`. Measured on macOS with a process-group SIGINT, three times. On Julia 1.14 the driver exits 130, but a worker can be removed before it sees the interrupt.
- The `setup!` and `instantiate!` examples no longer pass `:delete` with `yes=true`. A first-time remote uses `:rsync` and `:instantiate`. `:rsync` already refuses a remote path that is not empty.
- On Julia 1.14, Ctrl-C during `drive` prints `Interrupted. Cleaning up workers...`, removes the workers, and exits 130. It used to exit 1 with a `CancellationRequest` stacktrace. Julia 1.13 is unchanged.
- The first `julia -m DistSSHRun` compiles the subcommand it runs, not every subcommand. Commands, flags, and exit codes are unchanged.

## 0.1.9

- Rsync `--files-from` lists use NUL separators and protect names beginning
  with `#` or `;` from comment parsing, so every selected path is transferred.
- `push_cache!` transfers hosts with the same `DISTSSHKIT_JOBS` limit as
  other host work. The returned host rows stay in session order.
- A failed `collect` `find -newer` includes a short excerpt of that command's
  stderr. Collect warnings for an escaping path, and the host list on a path
  that arrived from more than one host, are sorted so the text does not depend
  on which host finished first.

## 0.1.8

- Since DistSSHRun 0.1.7, `setup --rsync` inside one git repository also applies `.gitignore` files above the send root.
- `setup --rsync` warns once when untracked files are left out by a `.gitignore` above the send root. The warning names the count, a few paths, and that file's path and line. Those files stay out of the send list. `.git/info/exclude` and `core.excludesFile` are not part of this warning.
- Directories in the send list ignore `.git/info/exclude` and `core.excludesFile`, the same rule as the file list. A negated pattern (`!dir/`) keeps the directory.
- A failed `git check-ignore` stops the send list, including when its stderr is empty. Exit 1 with empty stderr still means nothing matched.
- `rsync_send_list` returns the send list and does not warn. `setup --rsync` still warns once. A send root that is the git work tree does not scan ignored files for that warning.
- `setup --prune` and `setup --rsync` refuse `~`, `/`, a single directory under `/`, this machine's home, and a path containing `.` or `..`, the same paths `setup --delete` and `setup --clone` already refuse. The remote prune script also stops when the path resolves to that host's home or `/`.
- `setup` prints the path that mode changes. `--delete`, `--clone`, and `--rsync` no longer all print the project root when the operation uses another path. A refused path prints `Error:` and exits 1.
- `--confirm-path` and `setup!` `confirm_path` reject a newline or NUL before surrounding whitespace is removed.
- An SSH failure while checking a remote destination is reported as a probe failure. `setup --rsync` and `setup --clone` no longer tell you to delete a path that was never shown to exist. `remote_dest_status` still returns `:nonempty` on that failure.
- `setup --clone` creates the parent of a missing destination before `git clone`. An existing empty destination is left for git.
- `setup --check`, and `setup --sync` or `--pull` when the tree is already current, warn when a lock or path source would not ship. They still exit 0. A `Project.toml` that cannot be parsed is part of that warning and does not change the exit code. Clone and git sync keep the existing error for a path outside the work tree.
- `collect-missing` skips a relative path that would write outside the local collect root, including an absolute path taken from the remote listing. `collect-overwrite` refuses the transfer when the local root already contains such a symlink. A collect root reached through a symlink is compared after that symlink is resolved. The warning names the path.
- CLI `go` / `plan` / `pool` / `ride` / `size` re-read the project root on each call and restore `ARGS` after `_run_kit_cli_script`. Direct `size.jl` exits with `size_main`'s status. `drive --collect-missing` / `--collect-overwrite` honor `-q` / `--verbose` / `--progress`.
- When `go` `--output-dir` is outside the project, remote slot output is staged under `$remote_root/.distsshkit/go/<batch>/<slot>` and collected into the local `--output-dir`. A later successful slot no longer hides an earlier failure in `GoResult.run`.
- `setup` treats an unknown `-` option as `unknown setup option` (exit 1). Passing more than one `setup` mode flag or an unknown option to `plan` / `pool` / `size` warns that it will be an error in DistSSHRun 0.2.
- SSH preflight failure on `setup!` / `instantiate!` returns `cancelled=false` with `ok=false`. `instantiate_remotes`, `runtest_remotes`, and `cleanup_remote_workers` bound remote concurrency with `map_host_jobs`.

## 0.1.7

- `setup --rsync` inside a git work tree sends the file list from `git ls-files` with each directory's `.gitignore`, so negation patterns (`!path`) now apply. A tracked file that matches `.gitignore` is sent. `.git/info/exclude` and `core.excludesFile` still do not apply, and directories are still created even when empty. Path-source directories are sent whole, except `.git/` and `.distsshkit/`. A path source that is its own repository applies only its own `.gitignore`. Outside a git work tree, behavior is unchanged. A send path that contains a newline is an error, and so is an empty send list. A failed `git check-ignore` stops and prints that command's stderr.
- `setup --rsync` and `setup --sync` warn when `Manifest.toml` would not be the lock the workers instantiate. For rsync, an untracked ignored lock is missing from the send list. For git sync, the lock is not committed at `HEAD`. A path source whose `*.jl` or project files are ignored or untracked also warns on git sync. This will be an error.
- `setup --sync`, `setup --pull`, and `sync!` warn when the remote `HEAD` is not the local `HEAD`. The message names both branches. A hash that could not be read is a separate warning, not a mismatch. Only a real mismatch will be an error.
- `drive` and `collect!` warn when a collect root is the project root or a parent of it. That includes `DISTRIBUTED_COLLECT_DIRS=.` and a default root from `DISTRIBUTED_OUTPUT_DIR`. Point collect at a result directory inside the project. collect-overwrite also skips `.git/`. This will be an error.
- A failed `git push`, `git pull`, or `git clone` prints the command's own error text.
- Each host touches its own drive sentinel, so collect still runs when hosts share a directory. A remote path that contains a newline is skipped with a warning.
- `drive` warns when two hosts collect the same relative path. The last transfer remains. With `DISTSSHKIT_JOBS` greater than 1, which host remains is unspecified. Hosts that share one directory report every file, so the warning lists them all.
- `run.toml` `collect_dirs` for `drive` resolves relative paths from the project root.
- The DistSSHBase and DistSSHUp sources live under `lib/` with their own
  `Project.toml` and tests. DistSSHRun still includes them as submodules.
- Host talking and the juliaup verbs move into two internal submodules,
  `DistSSHRun.DistSSHBase` and `DistSSHRun.DistSSHUp`. Exported names do
  not change. DistSSHQueue and DistSSHKit can use these instead of their
  own copies.
- `resolve_pkg_project_dir` also skips a vendored DistSSHKit or
  DistSSHQueue stub, as DistSSHKit already did.

## 0.1.6

- `setup!(session, :delete; confirm_path)` and `setup!(session, :prune; confirm_path)` delete when that path matches the computed path, even when `yes=false`. Omitting `confirm_path` still follows `session.yes`. Other modes reject `confirm_path`.
- `setup --delete` and `setup --prune` delete when `--confirm-path` matches the computed path. A mismatch names that path in single quotes and exits 1. Without `--confirm-path`, `-y` and `DISTSSHKIT_YES` still skip the prompt and delete. That skip stops in 0.2. With neither, they ask for `delete` or `prune`.
- `setup --delete` and `setup --clone` refuse `~`, `/`, and a single directory under `/`.
- `setup --clone` also refuses when the git root would land on one of those. Pass `--remote-path`.
- A path containing `.` or `..` is refused. `setup --delete` stops when the remote path resolves to `~` or `/`.
- Remote shell words are quoted for `sh`. An SSH name that starts with `-` is rejected.
- `DISTRIBUTED_SSH_OPTS` is split with shell quoting. A quoted value that contains spaces stays one argument. An unmatched quote is an error. A non-empty value still replaces the default options.
- rsync `-e` quotes each option, so a path with spaces stays one argument.
- `drive` and `size` print the SSH error when the connection itself fails. A host where the remote shell ran and Julia is absent still says Julia was not found. An SSH failure is not cached for the rest of the process.

## 0.1.5

- `wait` on a detached `KitProcess` is on the API page. `drive_host_status` points at `DriveResult`, not a field of it.

## 0.1.4

- Demo scripts that load a package use DistSSHKit when the active project lists it in direct `[deps]`, and DistSSHRun otherwise.
- `using` follows `--project`, not a Project.toml found by walking from the working directory.

## 0.1.3

- CLI help only. `setup` lists `--cleanup` and `--delete` separately.
- The time-table note on `go`, `drive`, and `setup` sits after Options.

## 0.1.2

- Host talking and the juliaup verbs live in this package (`base/` and `up/`).
- This package does not depend on DistSSHBase or DistSSHUp.
- The commands are `up add`, `up default`, `up update`, and `up status`.
- Help no longer lists `setup --juliaup` or `setup --juliaup-update`. Those flags still succeed and warn, and the warning names `up`.

## 0.1.1

- The README and the docs index lead with this package.
- Install with `pkg> add DistSSHRun`. The command is `julia -m DistSSHRun`. From Julia, `go!("job.jl")`.
- The API page groups those names. The dependency plan stays in the 0.1.0 note.

## 0.1.0

- First release of the run surface. DistSSHRun is the DistSSHKit execution layer moved into this package: `setup`, `go`, `ride`, `drive`, `plan`, `size`, `pool`, `demo`, and `progress`.
- Today, DistSSHKit 0.9 still contains that run and does not depend on DistSSHRun. DistSSHQueue depends on DistSSHKit. Users add DistSSHKit.
- The manual is the DistSSHKit manual. The command is `julia -m DistSSHKit`.
- `julia -m DistSSHRun` is the same entry when DistSSHRun is a direct dependency.
- Later, DistSSHQueue depends on DistSSHRun.
- DistSSHKit depends on DistSSHQueue and reexports DistSSHRun, so users still add DistSSHKit and run `julia -m DistSSHKit`. Queue depends on this package so Kit can depend on Queue.
