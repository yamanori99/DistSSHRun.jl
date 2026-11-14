category: breaking

- `drive`, `ride`, and `go` now fail closed when the controller has no active
  Manifest digest (`manifest.sha256` from `run_identity`): launch stops before
  workers or remote go slots are verified (no silent skip). The error states
  what failed, the controller host and project path, why unpinned versions are
  unsafe, fix steps (`Pkg.instantiate` when a project file exists, otherwise
  check the `--project` path), and that `--unsafe-heterogeneous` waives only
  Manifest/Project digest verification (recorded as unverified). Julia build
  and DistSSH* versions must still match. Provenance carries
  `environment.verification` = `verified` or `unverified` (with reason).
- When verification runs, Julia build, `pkg.*`, and Manifest/Project byte
  mismatches are collected in one report (paths and lock file names are not
  compared). An empty Julia commit on either side is a mismatch. Previously
  skipped checks can surface once a Manifest exists. `--unsafe-heterogeneous`
  does not waive Julia build or DistSSH* version checks. Worker snapshots load
  TOML in the same call that parses the Manifest; that parse uses
  `invokelatest` so `pkg.*` versions are read instead of being dropped.