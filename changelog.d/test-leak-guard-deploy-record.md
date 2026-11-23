category: skip
no user-facing change

- Drive and go unit tests that plant an active deploy record put the previous
  record back after the testset, so a parallel worker that later runs
  `workers.jl` does not fail with
  `shipped tree content digest mismatch on controller: Project.toml`.
- The leak guard fails a test file that leaves `active_deploy_record` or
  `active_source_selection`, then clears both so the next file on a reused
  parallel worker starts clean.
- `add_drive_workers! errors when nothing joins` asserts `_NO_WORKERS_JOINED`
  instead of any `ErrorException`, so a leftover deploy record cannot pass it.
