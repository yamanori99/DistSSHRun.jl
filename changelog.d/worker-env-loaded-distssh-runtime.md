category: breaking

- `drive`, `ride`, and `go` compare loaded DistSSH* packages on the controller,
  workers, and go SSH slots (`loaded.<Name>.version`, `.uuid`, and `.tree` from
  `Base.loaded_modules`, with `tool_require` when a required package is not yet
  loaded). `DistSSHBase` and `DistSSHRun` are always required; `DistSSHQueue` is
  required on a queue host; `DistSSHKit` and other DistSSH packages are compared
  when either side has them loaded. Tree hashes use git-sha1 on `pkgdir`. These
  checks fail closed and are not waived by `--unsafe-heterogeneous`. A host whose
  depot resolves a different version or tree than the controller now fails.
- Go parent slots probe the slot Julia process (with `worker_env_pairs`) instead
  of copying Manifest `pkg.*` lines from the controller.