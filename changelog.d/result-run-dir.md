category: added

- `DriveResult`, `GoResult`, `RideResult`, and `KitRunResult` carry `run_dir`. Omitted values stay `nothing`, so existing positional calls still construct. A seven-argument `GoResult` still takes `failed_step` in that position and fills `run_dir` from the active `DISTSSHKIT_RUN_DIR`. `go!` and `ride!` do the same. `ride!` keeps that directory on `RideResult` after it restores the previous `DISTSSHKIT_RUN_DIR`. `drive!` returns the directory that run allocated. `result_provenance` reads that directory's `run.toml`. `kit.result` records `run_dir` when one is known.
