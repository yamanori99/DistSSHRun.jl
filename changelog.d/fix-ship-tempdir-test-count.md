category: skip
no user-facing change

- `ship.jl` tempdir cleanup check used the process-wide temp directory, so parallel runs varied the `@test` count. It now uses a private `TMPDIR` and asserts the directory stays empty.
