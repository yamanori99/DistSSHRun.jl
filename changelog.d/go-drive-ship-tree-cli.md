category: breaking

- `go --ship-tree` and `drive --ship-tree` are errors. They are not aliases.
  Prepare with `setup ship-tree` (transfer/verify only), then
  `setup instantiate` / `setup check` when needed, then `go` / `drive`
  `--run-id ID`. `--allow-external-symlinks` on `go` / `drive` is the same
  error; pass it to `setup ship-tree`. `go!` / `drive!` / `sync!` still
  accept `sync=:ship_tree`. Detached `execute!(…; sync=:ship_tree)` is an
  error before spawn. An outside script is `extra_files` / `--extra-file`
  on that ship (one file, at `_distsshrun_external/<basename>`), then
  `execute!(…; run_id=id)` or `go` / `drive --run-id ID`.
  `sync=:sync` and `run_id=` detached argv are unchanged. `--sync` on
  `go` / `drive` is unchanged. There is no top-level `ship` command.
  DistSSHQueue `submit go|drive` calls `parse_*_args` then
  `execute_kwargs_from_parsed`. On a queue host / `DISTSSHQUEUE_LOCAL=1`,
  `_main` `print_cli_error`s that parse message (and names DistSSHKit
  setup, not DistSSHQueue setup). A client without a queue target still
  hits `require_queue_target!` first because `_submit_requests_help`
  swallows the parse error; that order is a Queue companion.
