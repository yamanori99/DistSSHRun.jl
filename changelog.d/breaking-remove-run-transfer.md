### Breaking

- `go` / `drive` / `execute!` / `pipeline!` no longer copy code on run.
  `--git-sync`, `--ship-tree`, `--sync`, `--skip-git-guard`, and related API
  `sync=` kwargs are rejected with setup guidance.
- Deploy first: `setup git-sync`, `setup ship-tree`, then `go` / `drive`
  `--snapshot ID` (or last-snapshot / git checkout).
- `setup git-sync --skip-git-guard` allows a dirty local tree; deploy record
  sets `dirty=true`.
- Removed in-process `_LAST_SHIP` snapshot default; use local
  `last-snapshot.toml`, deploy record, or `--snapshot`.
