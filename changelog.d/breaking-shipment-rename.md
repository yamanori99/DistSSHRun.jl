---
category: breaking
---

- `DistSSHShip.ShipPack` → `Shipment`, `DistSSHShip.ShipResult` →
  `ShipmentReceipt` (no compatibility aliases). On-remote ship record
  `<dest>/.distssh/ship.toml` → `<dest>/.distssh/shipment.toml`; writers
  use only `shipment.toml`. `read_ship_record` and related readers still
  accept legacy `ship.toml` when `shipment.toml` is missing or invalid.
