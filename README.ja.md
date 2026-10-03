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

DistSSHRun は、
[DistSSHKit](https://github.com/yamanori99/DistSSHKit.jl)
の実行層をこのパッケージへ移したものである。SSH で共有マシンに載せる一回の
実行で、`setup`、`go`、`ride`、`drive`、`plan`、`size`、`pool`、`demo`、
`progress` を持つ。対応は **macOS、Linux、WSL2 Ubuntu** (ネイティブ Windows
は対象外)。

いま、DistSSHKit 0.9 はその実行を自分で持ち、DistSSHRun には依存していない。
[DistSSHQueue](https://github.com/yamanori99/DistSSHQueue.jl)
は DistSSHKit に依存する。利用者は DistSSHKit を足す。手順は
[DistSSHKit のマニュアル](https://yamanori99.github.io/DistSSHKit.jl/stable/)
にある。打つコマンドは `julia -m DistSSHKit` である。

あとで、DistSSHQueue は DistSSHRun に依存する。DistSSHKit は DistSSHQueue
に依存し、DistSSHRun を reexport する。利用者はこれまでどおり DistSSHKit
を足し、`julia -m DistSSHKit` を打つ。Queue がこのパッケージに依存するので、
Kit は Queue に依存できる。

## インストール

普段は次を足す。

```julia
pkg> add DistSSHKit
```

このパッケージを直接依存にするときは次を足す。

```julia
pkg> add DistSSHRun
```

Julia **1.13+**。ホストには **`ssh`** と **`rsync`** が要る。git で配るときは **`git`** も要る。

## コマンド

```bash
julia -m DistSSHKit setup --check child:host1
julia -m DistSSHKit go SCRIPT.jl
julia -m DistSSHKit ride parent:2 SCRIPT.jl
julia -m DistSSHKit drive parent:2 SCRIPT.jl
julia -m DistSSHKit plan SCRIPT.jl
julia -m DistSSHKit size
julia -m DistSSHKit pool
```

DistSSHRun を直接依存にしているときは、`julia -m DistSSHRun` が同じ入口になる。
