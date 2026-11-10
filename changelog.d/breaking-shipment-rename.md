category: breaking

- `DistSSHShip.ShipPack` → `Shipment` and `DistSSHShip.ShipResult` →
  `ShipmentReceipt` (no deprecated aliases; same names under
  `DistSSHRun.DistSSHShip`). On-remote ship record
  `<dest>/.distssh/ship.toml` → `<dest>/.distssh/shipment.toml`; new
  releases write only `shipment.toml`. `read_ship_record` and related
  readers still accept legacy `ship.toml` when `shipment.toml` is missing or
  invalid; when both exist, `shipment.toml` wins.
