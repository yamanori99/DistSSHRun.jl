category: breaking

- `go --ship-tree` and `drive --ship-tree` are errors. They are not aliases.
  Prepare with `setup ship-tree` (transfer/verify only), then
  `setup instantiate` / `setup check` when needed, then `go` / `drive`
  `--snapshot ID`. `--allow-external-symlinks` on `go` / `drive` is the same
  error; pass it to `setup ship-tree`. `go!` / `drive!` / `sync!` still
  accept `sync=:ship_tree`. Detached `execute!(…; sync=:ship_tree)` cannot
  emit the removed CLI flag; pass `snapshot=` after setup. `--sync` on
  `go` / `drive` is unchanged. There is no top-level `ship` command.
