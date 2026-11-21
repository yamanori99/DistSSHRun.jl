category: skip
no user-facing change

- `test/parallel.jl` includes each test file into its own worker sandbox module so bindings do not leak across files on a reused worker.
