category: breaking

- Ship writes a minimal `run.toml` under each remote `runs/<run_id>/` with `schema`, `writer`, and `kind = "ship"` only. `setup --delete` refuses a Ship leaf whose `run.toml` is present but not DistSSHRun-owned. `setup --prune` applies the same check to `.distsshkit` candidates (including nested stamps under a candidate). A missing file (older trees) still uses structural checks only.
