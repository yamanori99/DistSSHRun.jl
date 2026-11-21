category: breaking

- Shipped trees store per-file git blob digests in `.distssh/deploy.toml`,
  ship regular files as read-only (`0444`) at pack and after verified extract,
  and re-verify the worker snapshot at launch (`drive`, `ride`, `go`). A drifted
  controller tree at job end is warned once and recorded in provenance. SSH remote
  workers use `JULIA_LOAD_PATH=@:@stdlib` only (job packages via `--project=`).
