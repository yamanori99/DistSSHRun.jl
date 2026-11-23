## Fix

- Drive and go unit tests that plant an active deploy record restore it in
  `finally`, so a parallel worker that later runs `workers.jl` no longer fails
  with `shipped tree content digest mismatch on controller: Project.toml`.
- The leak guard fails a test file that leaves `active_deploy_record` or
  `active_source_selection` changed.
- `add_drive_workers! errors when nothing joins` asserts `_NO_WORKERS_JOINED`
  instead of any `ErrorException`, so a leftover deploy record cannot pass it.
