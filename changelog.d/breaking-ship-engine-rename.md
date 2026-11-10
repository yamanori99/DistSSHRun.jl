category: breaking

- **DistSSHShip 0.3.0:** rename the unregistered engine API for pack/ship
  vocabulary. `snapshot` / `ShipSnapshot` → `pack_tree` / `ShipPack`;
  `transfer_tree` → `ship`; `TransferResult` / `TransferHostResult` →
  `ShipResult` / `ShipHostResult`; `send_paths` → `pack_paths`;
  shipped-record helpers → `ship_record_*`; remote metadata file
  `.distssh/shipped.toml` → `.distssh/ship.toml` (schema still `1`).
  `write_shipped_record!` → `write_ship_record` (no `!`; remote I/O only).
  Source files `snapshot.jl` / `transfer.jl` → `pack.jl` / `ship.jl`.
  DistSSHRun call sites updated; Run pack/send names stay for a later PR.
