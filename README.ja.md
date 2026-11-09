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

DistSSHRun は、SSH で共有マシンに載せる一回の実行である。`setup`、`up`、
`go`、`ride`、`drive`、`hostinfo`、`pool`、`demo`、`progress` を持つ。
対応は **macOS、Linux、WSL2 Ubuntu** (ネイティブ Windows は対象外)。

手順の詳細は
[DistSSHKit のマニュアル](https://yamanori99.github.io/DistSSHKit.jl/stable/)
にある。

## インストール

```julia
pkg> add DistSSHRun
```

Julia **1.13+**。

### ホスト

- **`ssh`** が要る。collect、go の slot pull-back、ship、
  `push_cache!` は SSH 上の stdlib Tar で送る。
- collect、pull-back、`push_cache!` にはリモートの Julia
  実行ファイルが要る（`--julia`、または自動検出）。
  `push_cache!` はその Julia が stdlib の `Tar` と `SHA` を
  読めることも要る。
- **`git`** が要るのは clone / sync / pull のときだけである。

### コピーしたファイル

- 元の mtime は残らない。pull-back は展開したファイルを `touch`
  する。ship は `touch` せず、展開したときの時刻のままである。
- 実行可能でないファイルはモード `0644`、実行可能なファイルは
  `0755` になる。

### Ship

`setup ship-tree`（その後 `setup instantiate`、それから `go` / `drive --snapshot ID`）:

- ship の根を歩き、各ディレクトリの `.gitignore` を適用する
  （大文字小文字を区別する）。`.git/info/exclude`、
  `core.excludesFile`、根より上の `.gitignore` は使わない。
  git は起動しない。
- 送る根は渡したプロジェクトのディレクトリであり、その上の
  workspace の Manifest ディレクトリには広げない。根の外の
  Manifest と path 依存は載せず、警告する。
- gitignore された `Project.toml`、`JuliaProject.toml`、
  `Manifest.toml`、`JuliaManifest.toml` は載せず、警告を 1 行出す。
  gitignore された `LocalPreferences.toml` も載らない。載せるには
  `!LocalPreferences.toml` を書く。
- 1 ファイルが 50 MiB を超える、または送る合計が 100 MiB を超えると
  警告する（`DISTSSHKIT_SHIP_WARN_FILE_BYTES`、
  `DISTSSHKIT_SHIP_WARN_TOTAL_BYTES`。不正な値はエラー）。
  256 MiB の上限は従来どおり失敗する。宣言した入力は載らない。
- 展開先は `<remote_root>/runs/<run_id>/src/` で、横に空の `out/`
  と DistSSHRun の短い `run.toml` stamp を置く。リモート根は先に
  存在しなければならない（`setup remote-root`）。
- `--rsync` は 0.2.0 で削除した。`setup delete` と `setup prune` は
  `--confirm-path` が要る。`-y` では消さない。ある stamp が
  DistSSHRun 所有でなければ拒否する。

### リモートのシェル

- ログインシェル（`$SHELL`）は POSIX 互換（`sh`、`bash`、`dash`、
  `zsh`）である。`ssh host command` は `$SHELL -c` で実行し、
  ログインシェルにはしない。
- Distributed の `SSHManager` はワーカーを `sh -l -c` で起動し、
  この包みは変えられない。`fish` と `csh` は未対応である。`fish`
  は引用の意味を黙って変える（シングルクォート内のバックスラッシュ）。
- `-` で始まる SSH 名（`user@-host` を含む）は拒否する。ホストまたは
  リモートパスに制御文字（NUL、改行、その他）が含まれるときも拒否する。

`julia -m DistSSHRun help setup` を見る。

## コマンド

打つコマンドは `julia -m DistSSHRun` である。
フラグは `julia -m DistSSHRun help go` で見る。

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

## ドキュメント

公式ドキュメントの本体は英語である。

- [Home](https://yamanori99.github.io/DistSSHRun.jl/stable/)
- [API](https://yamanori99.github.io/DistSSHRun.jl/stable/api/)
- [DistSSHKit](https://yamanori99.github.io/DistSSHKit.jl/stable/)

DistSSHRun `b568025c-2759-4ef1-8b14-17d00e2cd000`
