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

DistSSHRun is the
[DistSSHKit](https://github.com/yamanori99/DistSSHKit.jl)
execution layer moved into this package. It is one run on shared machines
over SSH: `setup`, `go`, `ride`, `drive`, `plan`, `size`, `pool`, `demo`,
and `progress`. Supported on **macOS, Linux, and WSL2 Ubuntu** (not native
Windows).

Today, DistSSHKit 0.9 still contains that run and does not depend on
DistSSHRun. [DistSSHQueue](https://github.com/yamanori99/DistSSHQueue.jl)
depends on DistSSHKit. Users add DistSSHKit. The manual is the
[DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/stable/).
The command is `julia -m DistSSHKit`.

Later, DistSSHQueue depends on DistSSHRun. DistSSHKit depends on
DistSSHQueue and reexports DistSSHRun, so users still add DistSSHKit and
run `julia -m DistSSHKit`. Queue depends on this package so Kit can depend
on Queue.

## Install

Day-to-day:

```julia
pkg> add DistSSHKit
```

Direct dependency of this package:

```julia
pkg> add DistSSHRun
```

Julia **1.13+**. Hosts need **`ssh`** and **`rsync`**. Git deploys also
need **`git`**.

## Commands

```bash
julia -m DistSSHKit setup --check child:host1
julia -m DistSSHKit go SCRIPT.jl
julia -m DistSSHKit ride parent:2 SCRIPT.jl
julia -m DistSSHKit drive parent:2 SCRIPT.jl
julia -m DistSSHKit plan SCRIPT.jl
julia -m DistSSHKit size
julia -m DistSSHKit pool
```

`julia -m DistSSHRun` is the same entry when this package is a direct
dependency.
