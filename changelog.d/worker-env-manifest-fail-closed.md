category: breaking

- `drive`, `ride`, and `go` now fail closed when the controller has no active
  Manifest digest (`manifest.sha256` from `run_identity`): launch stops before
  workers or remote go slots are verified (no silent skip). The error states
  what failed, the controller host and project path, why unpinned versions are
  unsafe, fix steps (`Pkg.instantiate` when a project file exists, otherwise
  check the `--project` path), and that `--unsafe-heterogeneous` skips
  verification and records the run as unverified. Provenance carries
  `environment.verification` = `verified` or `unverified` (with reason).
- When verification runs, Julia version/commit, `pkg.*`, and Manifest/Project
  byte mismatches are collected in one report (paths and lock file names are
  not compared). Previously skipped checks can surface once a Manifest exists.