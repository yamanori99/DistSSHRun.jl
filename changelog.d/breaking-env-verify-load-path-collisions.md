category: breaking

Closes #468

- Local workers use `JULIA_LOAD_PATH=@:@stdlib` only (no script directory or
  active-project load-path extras). Drive restricts controller `LOAD_PATH` to
  `@` and `@stdlib` while the job project is active.
- `drive` / `go` verify package identity collisions between already-loaded
  packages and the job Manifest (UUID and version) with what/where/why/fix
  errors before workers run.
- `setup instantiate` and `instantiate!` run `Pkg.instantiate` only after
  deployed Manifest bytes match `deploy.toml` `manifest_hash`. Deploy records
  include `instantiated = false` at ship; successful remote instantiate sets
  `instantiated = true` when the Manifest hash is unchanged.
