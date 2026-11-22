category: skip
no user-facing change

- `integration/go/overlap.jl` runs serial after the parallel batch so the local overlap wall-clock oracle is not starved by other workers.
