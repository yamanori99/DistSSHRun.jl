category: added

- `DistSSHShip` writes `<extract_dest>/.distssh/shipped.toml` (`schema = 1`) on
  [`transfer_tree`](@ref) by default (`complete` in-progress then complete).
  Public `build_shipped_record`, `write_shipped_record!`, `read_shipped_record`,
  `read_shipped_record_status`, `shipped_record_status`, and
  `verify_shipped_record`. DistSSHShip **0.2.0**.
