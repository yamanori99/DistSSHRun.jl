category: breaking

- Remove the `ride` CLI, `ride!`, `parse_ride_args`, `RideResult`, and `execute!(:ride, ...)`.
  Unknown subcommand `ride` prints a one-line hint: use `drive` with `pmap`.
- Migrate scripts by rewriting `map` to `pmap` and running `drive`. For `filter`,
  use `xs[pmap(f, xs)]` (or another pattern that keeps elements, not booleans).
  Effect-free rewrite and `--spi-check` are gone.
- Legacy on-disk records (`run.toml` / `kit.result` with `kind = "ride"`) remain readable
  for prune and result recovery.
