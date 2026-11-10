category: fixed

- `drive` CLI rejects `--sync` / ship-tree pre-run sync combined with
  `--run-id`, matching `drive!`, `go`, and `go!`. Previously the CLI could
  sync a git checkout and bypass snapshot selection instead of erroring, as
  documented in snapshot selection (`--run-id` cannot combine with
  `--sync` / `--ship-tree`).
