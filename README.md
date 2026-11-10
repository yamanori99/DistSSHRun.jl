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
Supported on **macOS, Linux, and WSL2 Ubuntu** (not native Windows).

The longer guide is the
[DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/stable/).

## Install

```julia
pkg> add DistSSHRun
```

Julia **1.13+**.

### Hosts

- **`ssh`** is required. Collect, go slot pull-back, ship, and
  `push_cache!` send bytes with stdlib Tar over SSH.
- Collect, pull-back, and `push_cache!` need a remote Julia
  executable (`--julia`, or auto-detect). `push_cache!` also needs
  that Julia to load stdlib `Tar` and `SHA`.
- **`git`** is required only for `setup git-clone`, `setup git-sync`, and
  `setup git-pull`.

### Copied files

- Original mtimes are not kept. Pull-back `touch`es extracted files.
  Ship does not `touch`; files keep the extract-time mtime.
- A non-executable file arrives as mode `0644`, and an executable
  file as `0755`.

### Ship

`setup ship-tree` (then `setup instantiate`, then `go` / `drive --run-id ID`):

- Walk the ship root and apply each directory's `.gitignore`
  (case-sensitive). `.git/info/exclude`, `core.excludesFile`, and a
  `.gitignore` above the ship root are not used. No git binary is run.
- The tar root is the project directory when every path dependency stays
  inside it. A relative path dependency outside it, or a workspace member,
  ships under the common ancestor. An absolute path, or a root of `$HOME`
  or `/`, is an error. `setup ship-tree --extra-file PATH` (repeatable;
  this version accepts one path) stores
  that file at `_distsshrun_external/<basename>`.
- A gitignored `Project.toml`, `JuliaProject.toml`, `Manifest.toml`,
  or `JuliaManifest.toml` is left out with one warning. A gitignored
  `LocalPreferences.toml` is left out too; add `!LocalPreferences.toml`
  to ship it.
- A file over 50 MiB, or a send list over 100 MiB, prints a warning
  (`DISTSSHKIT_SHIP_WARN_FILE_BYTES`,
  `DISTSSHKIT_SHIP_WARN_TOTAL_BYTES`; an invalid value is an error).
  The 256 MiB cap still stops the ship. Declared inputs are left out.
- Extract is into `<remote_root>/runs/<run_id>/src/`, with empty
  `out/` beside it and a minimal DistSSHRun `run.toml` stamp. The
  missing remote root is created when safe (`~/…` under home, or absolute
  with an existing parent; see `help setup`). Absolute roots also refuse
  `/`, a single directory under `/`, `.`/`..`, and this machine's home.
  `setup remote-root` still creates one absolute path only (`--deploy-root PATH`).
- `--rsync` was removed in 0.2.0. `setup delete` and `setup prune` need
  `--confirm-path`; `-y` does not authorize them. A present unowned
  stamp is refused.

### Remote shell

- The login shell (`$SHELL`) must be POSIX-compatible (`sh`, `bash`,
  `dash`, or `zsh`). `ssh host command` runs `$SHELL -c`, not a login
  shell.
- Distributed's `SSHManager` starts workers with `sh -l -c`, and that
  wrap cannot be changed. `fish` and `csh` are unsupported. `fish` can
  silently change quoting (a backslash inside single quotes).
- An SSH name that starts with `-`, including `user@-host`, is
  rejected. A host or remote path that contains a control character
  (NUL, newline, or any other) is rejected.

See `julia -m DistSSHRun help setup`.

## Commands

The command is `julia -m DistSSHRun`.
See flags with `julia -m DistSSHRun help go`.

```bash
julia -m DistSSHRun setup check child:host1
julia -m DistSSHRun go SCRIPT.jl
julia -m DistSSHRun ride parent:2 SCRIPT.jl
julia -m DistSSHRun drive parent:2 SCRIPT.jl
julia -m DistSSHRun hostinfo
julia -m DistSSHRun pool
```

```julia
using DistSSHRun
go!("job.jl")
```

## Documentation

- [Home](https://yamanori99.github.io/DistSSHRun.jl/stable/)
- [API](https://yamanori99.github.io/DistSSHRun.jl/stable/api/)
- [DistSSHKit](https://yamanori99.github.io/DistSSHKit.jl/stable/)
- Versioning and releases: [DistSSHKit manual, Releasing](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/releasing.md)

DistSSHRun `b568025c-2759-4ef1-8b14-17d00e2cd000`
