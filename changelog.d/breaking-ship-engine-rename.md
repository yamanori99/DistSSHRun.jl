category: breaking

- **DistSSHShip:** pack/ship vocabulary for 0.2.0. `ShipSnapshot` /
  `ShipPack` → `pack_tree` / `Shipment`; `TransferResult` → `ShipmentReceipt`;
  `send_paths` → `pack_paths`; record helpers → `shipment_record_*`; remote
  metadata writes `<dest>/.distssh/shipment.toml` (schema 1) with legacy
  `ship.toml` read fallback. Source files `snapshot.jl` / `transfer.jl` →
  `pack.jl` / `ship.jl`.
