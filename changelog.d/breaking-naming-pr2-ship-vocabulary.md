category: breaking

- Rename `rsync_send_list` → `git_send_list` (no alias). Private helper
  `_rsync_send_list` → `_git_send_list`.
- Rename `DistSSHShip` remote record helpers `ship_record_*` →
  `shipment_record_*` (`shipment_record_logical_path`, `build_shipment_record`,
  `write_shipment_record`, `read_shipment_record`,
  `read_shipment_record_status`, `shipment_record_status`,
  `verify_shipment_record`). On-disk files stay `shipment.toml` with legacy
  `ship.toml` read fallback; TOML keys unchanged.
- Rename `ship_pack` → `pack_shipment`.
- Remove `instantiate_after_rsync!`. Remove `gitignore=` from `sync!` and
  `setup!`. Remove `PipelineConfig.sync` and ignore `SYNC_MODE` (no error).
- User-facing text: last-ship / ship-tree wording replaces obsolete “snapshot”
  labels where it meant deploy pin or ship selection.
