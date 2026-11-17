category: fixed

- Drive no longer tears down SSH workers when the shipped project tree is read-only and worker `Pkg.precompile` is skipped; launch still warns and continues (same as local `addprocs`).
