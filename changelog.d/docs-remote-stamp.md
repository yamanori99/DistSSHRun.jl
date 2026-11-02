category: changed

- `help setup` states that ship needs an existing `remote_root`, writes `out/` and a DistSSHRun `run.toml` stamp, and that `--delete` / `--prune` refuse an unowned stamp. The home page, README, and `setup!` notes match that. Controller `DISTSSHKIT_RUN_DIR/run.toml` stays distinct from the remote stamp. `teardown` is DistSSHQueue.
