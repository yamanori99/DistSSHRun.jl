# [Run options (generated from the option table)](@id Options)

The authoritative definitions live in `src/DistSSHRun/options/table.jl`.
Help text for `go`, `drive`, and `ride` is generated from the same rows.
CI fails when `--help` and this page drift from that table.

## Shared run-job flags

| Key | CLI | Environment | Default | Unsafe |
|-----|-----|-------------|---------|--------|
| `unsafe_skip_env_digests` | `--unsafe-skip-env-digests` | `DISTSSH_UNSAFE_SKIP_ENV_DIGESTS` | `false` | yes |
| `unsafe_expose_port` | `--unsafe-expose-port` | `DISTSSH_UNSAFE_EXPOSE_PORT` | `false` | yes |
| `unsafe_all_to_all` | `--unsafe-all-to-all` | `DISTSSH_UNSAFE_ALL_TO_ALL` | `false` | yes |
| `topology` | — | `DISTSSH_TOPOLOGY` | `auto` | no |
| `print_config` | `--print-config` | — | `false` | no |
| `dry_run` | `--dry-run` | — | `false` | no |

## Drive-only flags

| Key | CLI | Environment | Default | Unsafe |
|-----|-----|-------------|---------|--------|
| `unsafe_master_silence_exit` | `--unsafe-master-silence-exit` | `DISTSSH_UNSAFE_MASTER_SILENCE_EXIT` | `false` | yes |

## Precedence

Within one scope: **CLI → environment → default**. Per-host Distributed
`bind` overrides come from optional `bind` on each `[[hosts]]` row in a TOML
hosts file (IPv4 literal only; see [Placement](@ref Placement)). `drive`,
`ride`, and `--dry-run` validate every listed host before SSH; invalid `bind`
values fail closed (exit 2 on the CLI, not softened by `--best-effort`).

## Diagnostics

- `--print-config` resolves settings and prints each value with its source, then exits 0 without SSH.
- `--dry-run` prints placement, resolved topology and bind per host (with tunnel), and redacted worker env keys, then exits 0 without SSH.

## Removed CLI names (0.2.0)

| Old flag | Use instead |
|----------|-------------|
| `--unsafe-heterogeneous` | `--unsafe-skip-env-digests` |
| `--allow-mismatch` | `--unsafe-skip-env-digests` (digests only) |
| `-p` / `-pN` (drive, ride, go) | No short alias: `--local-workers N` (drive, ride) or `--local-slots N` (go) |
| `-l`, `--local` | SSH user as `user@host` in a hosts file |
| `-L` | `host:port` in a hosts file or SSH config (no `-L` forwarding flag) |
