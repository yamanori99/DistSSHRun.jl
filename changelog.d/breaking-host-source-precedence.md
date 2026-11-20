category: breaking

- Host lists come from exactly one source: CLI `--hosts`, `--hosts-file`, or `--machine-file` fully overrides `DISTSSH_HOSTS` / `DISTSSH_HOSTS_FILE` (no merge with env CSV).
- Jobs print `hosts (from …): …` and, when `DISTSSH_HOSTS` is set but overridden, `DISTSSH_HOSTS is set but overridden by --hosts` (or the matching CLI source).
- `--dry-run` plans include `hosts_source`.