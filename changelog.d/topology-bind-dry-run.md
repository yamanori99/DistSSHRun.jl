category: breaking

- TOML `[[hosts]]` optional `bind` overrides the loopback default per SSH destination; non-loopback binds still require `--unsafe-expose-port` (#461).
- `--dry-run` prints resolved topology, bind, and tunnel for each listed host (#461).
