category: changed

- `drive` / `go` with `sync=:ship_tree` start declared-input hashing after extract and finish it while instantiate, worker launch, and precompile run. If `go!` throws before that wait, cleanup still finishes the deferred hashes. An interrupt while worker init is waiting for that overlapped hash still finishes the hash, then reports the interrupt. Standalone `setup --ship-tree` still waits for hashes before it returns. `sync!(...; await_inputs=false)` defers the wait to `await_declared_input_hashes!`.
