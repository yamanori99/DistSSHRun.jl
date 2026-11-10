category: fixed

- `DistSSHShip.read_ship_record` no longer falls back to legacy `ship.toml`
  when `shipment.toml` is present but cannot be read over SSH. A read failure
  now raises `ArgumentError` instead of accepting a complete legacy record.
