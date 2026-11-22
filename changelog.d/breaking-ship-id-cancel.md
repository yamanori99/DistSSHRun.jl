category: breaking

- `ship_id` replaces `run_id` for a shipped tree. CLI `--ship-id` replaces `--run-id` (the old flag errors and names `--ship-id`). Remote layout is `ships/<id>/src`. `validate_ship_id` replaces `validate_run_id`. `result_ship_id` replaces `result_remote_run_id`.
- DistSSHBase owns one generic stop function. DistSSHRun adds methods on DetachedProcess and a run directory.
- `terminate!` and `terminate_run!` are removed.
- `print_rejected_command` prints `REMOVED_RIDE_SUBCOMMAND_HINT` for `ride` on the script branch too. A `run.toml` with `kind = "ride"` is not this package's manifest.
