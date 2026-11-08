category: breaking

- Snapshot source selection is explicit. `--snapshot ID` / `snapshot=` names
  `runs/<ID>/` under the already resolved deployment root (`--remote-path`
  stays location only). IDs must match `YYYYMMDDTHHMMSSZ-xxxxxx`; traversal
  and multi-component paths are refused. An explicit ID never falls back to
  the deploy root, lexical latest, or another ID. Every target host is
  validated before instantiate / check / runtest / go / drive / ride /
  collect mapping.
- After a successful extract, the remote leaf `run.toml` gains `complete =
  true`, `algorithm = "git-sha1"`, and `content_tree_hash` (the shipped tar
  hash). That marks transfer+extract finished; it is not a fresh remote tree
  re-hash. Incomplete or legacy stamps without `complete` are not selectable.
- When `--snapshot` is omitted, a local
  `<env_dir>/.distsshkit/last-snapshot.toml` may supply the ID (keyed by
  deploy root and successful host aliases). A missing or incompatible host
  set fails. Otherwise a git checkout with `Project.toml` at the deploy root
  on every host is used. Lexical latest `runs/*/src` is removed. The local
  record is a convenience default only; another local deployer can overwrite
  it between commands. Programmatic callers should pass
  `result_remote_run_id` / the returned ID. `go` / `drive --ship-tree` pass
  that invocation's ID into instantiate and work-root resolution.
- Controller `provenance.shipped` may record `source_kind`, `deploy_root`,
  and `work_root` for runs that did not ship in-process. Collect / recovery
  mapping honors `--snapshot` / `snapshot=` (or the active selection) and
  does not rediscover today's latest leaf. Standalone `setup --ship-tree`
  remains transfer-only. Git `--sync` / `--pull` / `--clone` are unchanged.
