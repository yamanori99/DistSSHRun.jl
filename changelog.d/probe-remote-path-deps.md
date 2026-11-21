category: added

- No-sync `go`, `drive`, and `execute` probe each host for Manifest path
  dependencies (and Project `[sources]` paths, including workspace members)
  in the existing pre-launch dependency check. A missing directory reports
  per-host with the declared path, the expected location, deploy mode from
  `.distssh/deploy.toml` when present, and setup git-sync / ship-tree hints
  (no extra SSH round trip).
