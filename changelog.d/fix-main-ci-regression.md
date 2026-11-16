category: fixed

- Restore clap-like exit semantics after the 0.2.0 CLI batch: drive Ctrl-C exits 130 via `CliForegroundInterrupt`, demo installs return `Cint` success codes, and setup integration tests expect usage exit 2 where the CLI reports usage errors.
- Split `DistSSHShip` tests for JETLS include resolution.
- `apply_shared_cli_flags!` mirrors `session.yes` into `kit_noninteractive` so a prior `-y` cannot skip later setup confirmations.
- Local-only `ride!` resets the launch rank plan and runs worker init like drive (fixes `take_worker_rank` exhaustion and empty worker maps).