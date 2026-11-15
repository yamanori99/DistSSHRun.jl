category: fixed

- Drive and ride workers honor `DISTSSH_BLAS_THREADS`: `enable_threaded_blas`, `BLAS.set_num_threads`, and a mismatch error naming host and rank. Unset keeps one BLAS thread on workers.
- The first worker project precompile warns on failure (host, rank, error) instead of failing silently.
- Isolated drive child status fails closed on negative signals and on exit values outside `Cint`.
- Setup delete or clone cancellation no longer clears the last-ship default when no host changed.
- Setup ship-tree follow-up commands quote `--deploy-root` paths for the local shell.