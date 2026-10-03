# News

User-facing changes.
GitHub Releases may copy these sections (`Release notes:` on
`@JuliaRegistrator register`).

## 0.1.0

First release of the run surface. DistSSHRun is the DistSSHKit execution
layer moved into this package: `setup`, `go`, `ride`, `drive`, `plan`,
`size`, `pool`, `demo`, and `progress`.

Today, DistSSHKit 0.9 still contains that run and does not depend on
DistSSHRun. DistSSHQueue depends on DistSSHKit. Users add DistSSHKit.
The manual is the DistSSHKit manual. The command is `julia -m DistSSHKit`.
`julia -m DistSSHRun` is the same entry when DistSSHRun is a direct
dependency.

Later, DistSSHQueue depends on DistSSHRun.
DistSSHKit depends on DistSSHQueue and reexports DistSSHRun, so users
still add DistSSHKit and run `julia -m DistSSHKit`. Queue depends on
this package so Kit can depend on Queue.
