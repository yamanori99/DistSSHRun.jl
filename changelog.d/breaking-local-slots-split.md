category: breaking

- Split local placement CLI: `go` uses `--local-slots N` for local subprocess slots; `drive` and `ride` keep `--local-workers N` for Distributed workers on this machine. `go` rejects `--local-workers`.
- Default placement is zero local workers/slots for `drive` / `ride` until `--local-workers` or `N*host` tokens specify capacity. `go` with no hosts and no `--local-slots` still runs one local slot (labeled explicitly in launch and `--dry-run`); explicit `--local-slots 0` with no hosts remains an error. `DISTSSH_LOCAL_WORKERS` applies only to `drive` / `ride`, not `go`.
- Launch and `--dry-run` output show `local: <hostname>, N workers|slots` instead of the fixed `parent` label.
- Go slot directories, provenance slot labels, and placement provenance keys use plain host names (no `parent:` / `child:` prefixes).
- `setup` rejects `N*host` machine counts on CLI, hosts file, and `setup!` tokens (one operation per host).