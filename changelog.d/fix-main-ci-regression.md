category: fixed

- Restore clap-like exit semantics after the 0.2.0 CLI batch: drive Ctrl-C exits 130 via `CliForegroundInterrupt`, demo installs return `Cint` success codes, and setup integration tests expect usage exit 2 where the CLI reports usage errors.
- Split `DistSSHShip` tests for JETLS include resolution; `setup!` `:juliaup` respects `kit_noninteractive` without clearing it on every `apply_session_env!`.