category: added

- `run_identity` and `identity_mismatches` are public and are not exported. `run_identity(project)` is this process's Julia version, commit, and binary path, plus DistSSH* versions and the Manifest path of `project`. `identity_mismatches` returns the same lines `go`, `ride`, and `drive` already use (Julia build, `pkg.*`, and byte SHA-256 digests for Manifest and Project). `--unsafe-heterogeneous` waives only Manifest/Project digest lines during a job; Julia build and `pkg.*` mismatches are still reported.
