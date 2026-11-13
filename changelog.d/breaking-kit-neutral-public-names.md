category: breaking

- Rename public identifiers (no compatibility aliases):
  - `KitSession` → `DistSSHSession`
  - `KitRunResult` → `DistSSHJobResult`
  - `KitProcess` → `DetachedProcess`
  - `KitCliSession` → `CliSharedFlags`
  - `peel_kit_cli_flags` → `peel_shared_cli_flags`
  - `apply_kit_cli_session!` → `apply_shared_cli_flags!`
  - `kit_host_source_tokens` → `placement_source_tokens`
