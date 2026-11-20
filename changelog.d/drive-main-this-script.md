category: fixed

- In-process `drive!` calls `main()` only when this script defines it. A `main` left in `Main` by an earlier driver is not called, so a script without `main` no longer runs the previous driver's work.
