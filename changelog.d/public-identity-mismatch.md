category: added

- `run_identity`, `identity_mismatches`, and `parse_allow_mismatch` are public and are not exported. `run_identity(project)` is this process's Julia version, commit, and binary path, plus DistSSH* versions and the Manifest path of `project`. `identity_mismatches` returns the same lines `go`, `ride`, and `drive` already use (`julia`, `distssh`, `manifest`). `parse_allow_mismatch` accepts that comma list. Callers pass `allow` in. The process-global allow list is unchanged.
