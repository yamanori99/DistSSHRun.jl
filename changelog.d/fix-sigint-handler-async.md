## Fix

- The first Ctrl-C handler for drive wakes the event loop with `uv_async_send`
  only. Throwing from the signal handler is not async-signal-safe and could
  leave cleanup hung under load (timed-out `drive second SIGINT skips cleanup`
  on CI).
- Installing that handler errors when `signal(SIGINT)` returns `SIG_ERR`
  instead of leaving drive without an interrupt path.
