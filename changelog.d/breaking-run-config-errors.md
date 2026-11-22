category: breaking

- One option table drives shared `go` / `drive` / `ride` flags, `--help` lines, and docs. `--unsafe-heterogeneous` is removed; use `--unsafe-skip-env-digests` (usage error names the new flag). New unsafe opt-ins: `--unsafe-expose-port`, `--unsafe-all-to-all`. `--print-config` and `--dry-run` resolve config and exit without SSH.
- Typed errors use stable `DSSH-E###` codes with a registry and a common-errors docs page.
