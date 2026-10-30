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
`go`, `ride`, `drive`, `plan`, `size`, `pool`, `demo`, and `progress`.
Supported on **macOS, Linux, and WSL2 Ubuntu** (not native Windows).

The longer guide is the
[DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/stable/).

## Install

```julia
pkg> add DistSSHRun
```

Julia **1.13+**. Hosts need **`ssh`**. Collect and go slot pull-back use
stdlib Tar over SSH, and remote mtimes are not kept. Cache pull still needs
**`rsync`**. Ship uses stdlib Tar over SSH. Git deploys also need **`git`**.
`setup --ship-tree`, `go --ship-tree`, and `drive --ship-tree` extract the
git file list into `<remote_root>/runs/<run_id>/src/`. `--rsync` was removed
in 0.2.0. The remote login shell (`$SHELL`) must be POSIX-compatible
(`sh`, `bash`, `dash`, or `zsh`). `ssh host command` runs `$SHELL -c`, not
a login shell. Distributed's `SSHManager` starts workers with `sh -l -c`,
and that wrap cannot be changed. `fish` and `csh` are unsupported. `fish`
can silently change quoting (a backslash inside single quotes). An SSH
name that starts with `-`, including `user@-host`, is rejected. A host or
remote path that contains a control character (NUL, newline, or any other)
is rejected. See `julia -m DistSSHRun help setup`.

## Commands

The command is `julia -m DistSSHRun`.
See flags with `julia -m DistSSHRun help go`.

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

## Documentation

- [Home](https://yamanori99.github.io/DistSSHRun.jl/stable/)
- [API](https://yamanori99.github.io/DistSSHRun.jl/stable/api/)
- [DistSSHKit](https://yamanori99.github.io/DistSSHKit.jl/stable/)
- Versioning and releases: [DistSSHKit manual, Releasing](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/releasing.md)

DistSSHRun `b568025c-2759-4ef1-8b14-17d00e2cd000`
