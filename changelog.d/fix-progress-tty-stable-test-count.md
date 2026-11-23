category: skip
no user-facing change

- `_assert_tty_progress_payload` uses a fixed `@test` count so redraw volume
  does not change the suite total (#577). Pseudo-TTY suites move to `test/tty/`
  and run under `DISTSSH_TEST_GROUP=tty` (not default `Pkg.test()`).
