category: breaking

- `setup --ship-tree` / `go --ship-tree` / `drive --ship-tree` and
  `setup!(session, :ship_tree)` pack the git file list (`git ls-files -co
  --exclude-standard`) as a tar and extract it to
  `<remote_root>/runs/<run_id>/src/`. `run_id` is UTC plus 6 hex.
  `remote_root` after expansion must not be `$HOME` or `/`. The leaf
  directory is a plain `mkdir` (existing leaf fails). `--rsync` and
  `sync=:rsync` / `setup!(session, :rsync)` were removed; the usage error
  names `--ship-tree`. Collect, slot pull, and `push_cache!` still use
  rsync. Escaping symlinks are refused unless `--allow-external-symlinks`.
  Trees larger than 256 MiB fail. A later CLI `--instantiate` / `--check`
  needs `--remote-path` to that `src/` (`setup!` after `:ship_tree` in the
  same process uses it). `sync!(; mode=:ship_tree)` does not rewrite
  `session.remote`. `run.toml` and `provenance.toml` record `schema = 1`
  and `writer = "DistSSHRun x.y.z"`. Schema 1 no longer writes
  `diff_sha256`. `[shipped]` records `content_tree_hash` (`git-sha1`),
  bytes, files, host alias, and `run_dir_empty_at_start` when a ship ran.
  Env is names only; paths are `~` or relative; cookies are omitted.
  Unknown keys are ignored when reading. `[[inputs]]` / `outputs` are
  reserved and not written.
  Remaining rsync warns when PATH is openrsync. Project-local `sshflags`
  are ignored with a warning; SSH uses `DISTRIBUTED_SSH_OPTS` / `ssh_opts()`.
