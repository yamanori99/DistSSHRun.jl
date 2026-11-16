category: breaking

- Rename head placement CLI: `drive` and `ride` use `--head-workers N`; `go` uses `--head-slots N`. `--local-workers` and `--local-slots` are rejected with hints.
- Default placement is zero head workers/slots for `drive` / `ride` until `--head-workers` or `N*host` tokens specify capacity. `go` with no hosts and no `--head-slots` still runs one head slot (labeled explicitly in launch and `--dry-run`); explicit `--head-slots 0` with no hosts remains an error. `DISTSSH_HEAD_WORKERS` applies to `drive` / `ride`; go head slots are CLI-only.
- Launch and `--dry-run` output show `head: <hostname> (this machine|queue host), N workers|slots` instead of `local:` or the fixed `parent` label.
- Go slot directories, provenance slot labels, and placement provenance keys use plain host names (no `parent:` / `child:` prefixes).
- `setup` rejects `N*host` machine counts on CLI, hosts file, and `setup!` tokens (one operation per host).