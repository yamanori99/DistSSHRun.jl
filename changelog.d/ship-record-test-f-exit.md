category: fixed

- `DistSSHShip.read_ship_record` treats remote `test -f` exit code 1 only as a
  missing record file. Any other non-zero exit (for example command not found
  or SSH transport failure) or a failed `cat` is a read error and raises
  `ArgumentError` instead of treating the record as missing and falling back
  to legacy `ship.toml`.
