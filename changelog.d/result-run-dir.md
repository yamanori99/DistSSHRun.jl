category: added

- `DriveResult`, `GoResult`, and `KitRunResult` carry `run_dir`. Omitted values stay `nothing`, so existing positional calls still construct. `go!` fills `GoResult.run_dir` from the active `DISTSSHKIT_RUN_DIR`. `drive!` returns the directory that run allocated. `result_provenance` reads that directory's `run.toml`. `kit.result` records `run_dir` when one is known.
