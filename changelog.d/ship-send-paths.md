category: changed

- `DistSSHShip.send_paths` lists the relative paths one directory contributes
  to a ship tar (same rules as `ship_send_list` for that tree). Run
  `ship_send_list` delegates to it plus Run declared-input omit rules.
- Public `DistSSHShip.gitignore_paths` and `selected_paths` match the prior
  Run-only gitignore walk used in tests.
