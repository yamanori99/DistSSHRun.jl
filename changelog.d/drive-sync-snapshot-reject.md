category: fixed

- `drive` CLI rejects `--sync` / ship-tree pre-run sync combined with
  `--snapshot`, matching `drive!`, `go`, and `go!`. Previously the CLI could
  sync a git checkout and bypass snapshot selection instead of erroring, as
  documented in snapshot selection (`--snapshot` cannot combine with
  `--sync` / `--ship-tree`).
