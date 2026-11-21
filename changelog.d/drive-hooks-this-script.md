category: fixed

- In-process `drive!` calls `main()` and `prepare_workers!()` only when this script defines them. A hook left in `Main` by an earlier driver is not called. Before, a script without `main` ran the previous driver's `main` and reported success, and a script without `prepare_workers!` after one that had it failed with `UndefVarError` on the workers.
