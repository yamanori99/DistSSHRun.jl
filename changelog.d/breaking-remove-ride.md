category: breaking

- Remove the `ride` CLI, `ride!`, `parse_ride_args`, `RideResult`, and `execute!(:ride, ...)`.
  Unknown subcommand `ride` prints a one-line hint: use `drive` with `pmap`.
- Migrate scripts by rewriting plain `map` / `filter` to `pmap` and running `drive`.
  Effect-free rewrite and `--spi-check` are gone.
- Legacy on-disk records (`run.toml` / `kit.result` with `kind = "ride"`) remain readable
  for prune and result recovery.
