category: breaking

- Remove the `ride` CLI, `ride!`, `parse_ride_args`, `RideResult`, and `execute!(:ride, ...)`.
  Unknown subcommand `ride` prints a one-line hint: use `drive` with `pmap`.
- Migrate scripts by adding `using Distributed`, moving the work into `main()`,
  rewriting `map` to `pmap` there, and running `drive`. Drive includes the script
  before workers start, so a top-level `pmap` runs on the controller alone. For
  `filter`, use `xs[pmap(f, xs)]` (or another pattern that keeps elements, not booleans).
  Effect-free rewrite and `--spi-check` are gone.
- Legacy on-disk records (`run.toml` / `kit.result` with `kind = "ride"`) remain readable
  for prune and result recovery.
