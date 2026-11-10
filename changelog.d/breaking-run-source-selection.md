category: breaking

- Rename deploy-pin vocabulary: CLI `--snapshot` → `--run-id`; Julia keyword
  `snapshot=` → `run_id=`; remove `validate_snapshot_id` in favor of public
  [`validate_run_id`](@ref).
- `SnapshotSelection` → `SourceSelection`; `source_kind` `:snapshot` → `:ship`;
  field `snapshot_id` → `run_id`.
- Local record `last-snapshot.toml` → `last-ship.toml` (one-release read of the
  legacy filename and `snapshot_id` field).
- Controller `provenance.shipped` → `provenance.selection` (read fallback for
  `shipped` during collect recovery). Remote deploy record key `snapshot_id` →
  `run_id`.
- `resolve_snapshot_selection` → `resolve_source_selection`;
  `active_snapshot_selection` → `active_source_selection`;
  `read/write_last_snapshot_*` → `read/write_last_ship_*`;
  `forget_last_snapshot_default!` → `forget_last_ship_default!`.
- Module `snapshot_select.jl` → `source_selection.jl`.
