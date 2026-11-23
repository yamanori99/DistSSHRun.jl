category: skip
no user-facing change

- `cluster()` on builds with `Base.CANCEL_TOKEN` runs under `_with_driver_sigint_exceptions` so a subprocess can exit 130 instead of Julia's default SIGINT kill. The cluster SIGINT integration still checks owned worker removal; user and foreign worker retention is skipped on cancellation builds where `workers()` is already empty before teardown.