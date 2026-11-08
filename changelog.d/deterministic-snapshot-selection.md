category: breaking

- Snapshot source selection is explicit. `--snapshot ID` / `snapshot=` names
  `runs/<ID>/` under the already resolved deployment root (`--deploy-root`
  stays location only). IDs must match `YYYYMMDDTHHMMSSZ-xxxxxx`; traversal
  and multi-component paths are refused. An explicit ID never falls back to
  the deploy root, lexical latest, or another ID. Every target host is
  validated before instantiate / check / runtest / go / drive / ride /
  collect mapping.
- After a successful extract, the remote leaf `run.toml` gains `complete =
  true`, `algorithm = "git-sha1"`, and `content_tree_hash` (the Git tree hash
  of the shipped tar contents, not a byte hash of the tar file). That marks
  transfer+extract finished; it is not a fresh remote tree re-hash.
  Selection fail-closes unless every host stamp has DistSSHRun ownership
  (`schema` / `writer` / `kind = "ship"`), `complete = true`,
  `algorithm = "git-sha1"`, and a 40-digit hex `content_tree_hash`, and those
  hashes match across hosts. A local last-snapshot record whose stored hash
  disagrees with the remote stamp is refused. Incomplete, legacy, or
  `complete = true` stamps that omit those fields are not selectable.
- When `--snapshot` is omitted, a local
  `<env_dir>/.distsshkit/last-snapshot.toml` may supply the ID (keyed by
  deploy root and successful host aliases). A missing or incompatible host
  set fails. Otherwise a git checkout with `Project.toml` at the deploy root
  on every host is used. Lexical latest `runs/*/src` is removed. The local
  record is a convenience default only; another local deployer can overwrite
  it between commands. A successful `setup --delete` / `--clone` / `--sync` /
  `--pull` (and the matching `setup!` / `sync!` modes) clears that record for
  the matching deploy root so a later command can select the git checkout.
  Programmatic callers should pass `result_remote_run_id` / the returned ID.
  `go` / `drive --ship-tree` pass that invocation's ID into instantiate and
  work-root resolution. `--snapshot` cannot combine with `--sync` /
  `--ship-tree`.
- Controller `provenance.shipped` may record `source_kind`, `deploy_root`,
  and `work_root` for runs that did not ship in-process. Collect / recovery
  mapping honors `--snapshot` / `snapshot=` when given. When omitted, a
  present controller `DISTSSHKIT_RUN_DIR/run.toml` with
  `provenance.shipped` selects that original source (not a later local
  last-snapshot record or `_LAST_SHIP`). A DistSSHRun stamp without
  `provenance.shipped` is refused rather than falling back. In-flight runs
  that have not written `run.toml` still use the active selection. Deploy
  root and snapshot work root stay distinct: `drive --ship-tree` instantiates
  against the deploy root, then assigns the work-root ENV. Detached
  `execute!` forwards `snapshot=` / `--snapshot` to the child argv.
  Standalone `setup --ship-tree` remains transfer-only. Git `--sync` /
  `--pull` / `--clone` are unchanged.
