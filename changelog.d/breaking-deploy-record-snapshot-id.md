category: breaking

- Remote `deploy.toml` and local last-ship records no longer accept the legacy
  `snapshot_id` field; reading one raises `ArgumentError` with a rewrite hint
  (`run_id = …`). Setup already writes `run_id`. Edit existing files by hand;
  silent conversion is not supported.
- Local convenience records must use `.distssh/last-ship.toml`. Legacy
  `last-snapshot.toml` (only, or alongside `last-ship.toml`) is no longer read;
  errors name the path and show `mv` or `rm` hints. Writes already use
  `last-ship.toml` only.