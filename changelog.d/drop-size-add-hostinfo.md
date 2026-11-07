category: breaking

- Remove the `size` / `size!` command and RSS probe. Worker counts are
  explicit `parent:N` / `child:NAME:N` only. `WorkerPlan` stays in DistSSHRun.
- Remove DistSSHSize. Host facts live in DistSSHBase (`HostFacts`,
  `collect_host_facts`). The new `hostinfo` CLI (Kit/Run) prints them.
- `pool` still reports cores, RAM, and reachability. It no longer prints
  inferred slots or `--gb-per-worker` / `--mem-headroom` / `--parent-gb`.
- Drive no longer runs a heuristic memory-cap check. `--mem-headroom` and
  `--parent-gb` are errors.
- Missing hostinfo fields are `-` (never `0`). A host collection failure
  still prints that row and exits nonzero. Julia `--version` is text; it
  does not promise a commit. `go` / `ride` / `drive` / `serve` / `submit`
  do not probe hostinfo unless the command already needed those facts.
