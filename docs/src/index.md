# DistSSHRun

DistSSHRun is the [DistSSHKit](https://github.com/yamanori99/DistSSHKit.jl) execution layer moved into this package. It is one run on shared machines over SSH: `setup`, `go`, `ride`, `drive`, `plan`, `size`, `pool`, `demo`, and `progress`.

Today, DistSSHKit 0.9 still contains that run and does not depend on DistSSHRun. [DistSSHQueue](https://github.com/yamanori99/DistSSHQueue.jl) depends on DistSSHKit. Users add DistSSHKit. The manual is the [DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/stable/). The command is `julia -m DistSSHKit`.

Later, DistSSHQueue depends on DistSSHRun. DistSSHKit depends on DistSSHQueue and reexports DistSSHRun, so users still add DistSSHKit and run `julia -m DistSSHKit`. Queue depends on this package so Kit can depend on Queue.

`julia -m DistSSHRun` is the same entry when this package is a direct dependency.
