category: breaking

- Ship writes a minimal `run.toml` under each remote `runs/<run_id>/` with `schema`, `writer`, and `kind = "ship"` only. `setup --delete` and `--prune` refuse a leaf whose `run.toml` is present but not DistSSHRun-owned. A missing file (older trees) still uses structural checks only.
