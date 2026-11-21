category: breaking

- Job-default environment variables (`DISTSSH_*`, `JULIA_DISTRIBUTED_EXE`, placement hosts, and related keys) are copied once at each public entry (`parse_*_args`, `drive!`, `go!`, `setup!`, `pipeline!`, `DistSSHSession`). Parsers and option resolution read that snapshot only; changing `ENV` later in the same Julia process does not change an in-flight job's defaults.