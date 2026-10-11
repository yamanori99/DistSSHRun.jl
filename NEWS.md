# News

User-facing changes.
GitHub Releases may copy these sections (`Release notes:` on
`@JuliaRegistrator register`).

## Unreleased

- `setup!(session, :delete; confirm_path)` and `setup!(session, :prune; confirm_path)` delete when that path matches the computed path, even when `yes=false`. Omitting `confirm_path` still follows `session.yes`. Other modes reject `confirm_path`.
- `setup --delete` and `setup --prune` delete only when `--confirm-path` matches the computed path. Without it they print `Would remove` and exit 0. The path in that line is single-quoted so a shell does not expand `~`. `-y` and `DISTSSHKIT_YES` do not authorize them.
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
