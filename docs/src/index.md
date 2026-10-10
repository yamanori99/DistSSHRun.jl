# DistSSHRun

DistSSHRun is one run on shared machines over SSH: `setup`, `go`,
`ride`, `drive`, `plan`, `size`, `pool`, `demo`, and `progress`.
Supported on **macOS, Linux, and WSL2 Ubuntu** (not native Windows).

The command is `julia -m DistSSHRun`.

`pkg> app add DistSSHRun` still installs `distsshrun`. That command is
experimental. The binary is the Apps copy, not `--project=.`. Apps
fixes `JULIA_LOAD_PATH`, so `drive`, `size`, and `pool` still need
`julia -m DistSSHRun`.

DistSSHKit does not install a terminal command. When that package is
installed, `julia -m DistSSHKit` is the same entry.

The longer guide is the
[DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/stable/).

## Install

```julia
pkg> add DistSSHRun
```

Julia **1.13+**. Hosts need **`ssh`** and **`rsync`**. Git deploys also
need **`git`**.

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
