category: fixed

- Restore clap-like exit semantics after the 0.2.0 CLI batch: drive Ctrl-C exits 130 via `CliForegroundInterrupt`, demo installs return `Cint` success codes, and setup integration tests expect usage exit 2 where the CLI reports usage errors.
- Split `DistSSHShip` tests for JETLS include resolution.
- `apply_shared_cli_flags!` mirrors `session.yes` into `kit_noninteractive` so a prior `-y` cannot skip later setup confirmations.
- Local-only `ride!` resets the launch rank plan and runs worker init like drive (fixes `take_worker_rank` exhaustion and empty worker maps).
- Remote instantiate `-e` script wraps deploy-record lookup in a `begin` block for Julia 1.13 soft scope; ship-tree instantiate still enforces Manifest send rules.
- `go` remote slot shells seed a rank when the launch plan is empty.
