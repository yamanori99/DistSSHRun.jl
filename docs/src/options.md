# [Run options (generated from the option table)](@id Options)

The authoritative definitions live in `src/DistSSHRun/options/table.jl`
and `src/DistSSHRun/options/env_table.jl`.
Help text for `go` and `drive` is generated from the option rows.
CI fails when `--help` and this page drift from those tables.

## Shared run-job flags

| Key | CLI | Environment | Default | Unsafe |
|-----|-----|-------------|---------|--------|
| `unsafe_skip_env_digests` | `--unsafe-skip-env-digests` | `DISTSSH_UNSAFE_SKIP_ENV_DIGESTS` | `false` | yes |
| `unsafe_expose_port` | `--unsafe-expose-port` | `DISTSSH_UNSAFE_EXPOSE_PORT` | `false` | yes |
| `unsafe_all_to_all` | `--unsafe-all-to-all` | `DISTSSH_UNSAFE_ALL_TO_ALL` | `false` | yes |
| `print_config` | `--print-config` | — | `false` | no |
| `dry_run` | `--dry-run` | — | `false` | no |
| `topology` | — | `DISTSSH_TOPOLOGY` | `auto` | no |

## Drive-only flags

| Key | CLI | Environment | Default | Unsafe |
|-----|-----|-------------|---------|--------|
| `unsafe_master_silence_exit` | `--unsafe-master-silence-exit` | `DISTSSH_UNSAFE_MASTER_SILENCE_EXIT` | `false` | yes |

## Environment variables

User-facing names. A parent-to-child hand-off uses `DISTSSH_INTERNAL_*`
and is not an option. Test doubles are injected from `test/` and are not read as options.
An old Distributed-prefix name is an error that names the DistSSH replacement.
A numeric or boolean value that does not parse is an error that names the variable.
Unset uses the default. A present blank value is an error.

| Name | Type | Default | CLI | Meaning |
|------|------|---------|-----|---------|
| `DISTSSH_QUIET` | bool | `unset` | `--quiet` | hide terminal detail |
| `DISTSSH_PROGRESS` | bool | `unset` | `--progress` | live status |
| `DISTSSH_VERBOSE` | bool | `unset` | `--verbose` | full detail |
| `DISTSSH_YES` | bool | `unset` | `-y / --yes` | non-interactive confirm where allowed |
| `DISTSSH_HOSTS` | string | `unset` | `--hosts` | CSV of N*host tokens |
| `DISTSSH_HOSTS_FILE` | path | `unset` | `--hosts-file` | hosts file path |
| `DISTSSH_HEAD_WORKERS` | int | `unset` | `--head-workers` | LocalManager workers (drive) |
| `DISTSSH_JOBS` | int >= 1 | `1` | — | max concurrent host and go-slot SSH jobs |
| `DISTSSH_REQUIRE_ALL_HOSTS` | bool | `false` | `--require-all-hosts` | fail if any listed host is missing |
| `DISTSSH_BEST_EFFORT` | bool | `false` | `--best-effort` | continue after a host failure where allowed |
| `DISTSSH_UNSAFE_SKIP_ENV_DIGESTS` | bool | `false` | `--unsafe-skip-env-digests` | waive Manifest/Project digest checks |
| `DISTSSH_UNSAFE_EXPOSE_PORT` | bool | `false` | `--unsafe-expose-port` | allow non-loopback Distributed bind |
| `DISTSSH_UNSAFE_ALL_TO_ALL` | bool | `false` | `--unsafe-all-to-all` | allow worker-to-worker connections |
| `DISTSSH_UNSAFE_MASTER_SILENCE_EXIT` | bool | `false` | `--unsafe-master-silence-exit` | worker self-exit when the controller is silent |
| `DISTSSH_TOPOLOGY` | string | `auto` | — | Distributed topology: auto or master_worker |
| `DISTSSH_SSH_TUNNEL` | bool | `true` | — | SSH tunnel for worker connections |
| `DISTSSH_SSH_OPTS` | string | `unset` | — | extra OpenSSH tokens (shell-split) |
| `DISTSSH_PROJECT_ROOT` | path | `pwd` | — | local project root |
| `DISTSSH_REMOTE_PROJECT_ROOT` | path | `layout default` | `--deploy-root` | remote project root |
| `DISTSSH_OUTPUT_DIR` | path | `command default` | `--output-dir` | output / slot directory |
| `DISTSSH_RUN_DIR` | path | `allocated` | — | this execution's run directory |
| `DISTSSH_COLLECT_DIRS` | path list | `unset` | — | extra collect trees (colon-separated) |
| `DISTSSH_SKIP_COLLECT` | bool | `false` | — | skip post-run collect |
| `DISTSSH_HEARTBEAT_DEADLINE_SEC` | float > 0 | `unset` | — | required when master-silence-exit is on |
| `DISTSSH_HEARTBEAT_INTERVAL_SEC` | float > 0 | `30` | — | heartbeat ping interval |
| `DISTSSH_INIT_DELAY_SEC` | float > 0 | `5` | — | SSH worker init delay; local-only is 0 |
| `DISTSSH_PING_RETRIES` | int >= 1 | `6` | — | worker ping attempts during drive init |
| `DISTSSH_JOB_ID` | string | `unset` | — | job id for tagged remote processes |
| `DISTSSH_JOB_SEED` | uint64 | `unset` | — | controller job seed |
| `DISTSSH_WORKER_RANK` | int | `unset` | — | worker rank (set on the slot) |
| `DISTSSH_WORKER_SEED` | uint64 | `unset` | — | per-worker seed (set on the slot) |
| `DISTSSH_SHIP_WARN_FILE_BYTES` | int | `104857600` | — | warn when one shipped file exceeds this |
| `DISTSSH_SHIP_WARN_TOTAL_BYTES` | int | `unset` | — | warn when the shipped total exceeds this |
| `DISTSSH_PROGRESS_BG` | string | `unset` | — | progress accent: light or dark |
| `DISTSSH_BLAS_THREADS` | int >= 1 | `unset` | — | OpenBLAS/OMP threads on workers |
| `DISTSSH_SKIP_GLOBAL_WORKER_PKILL` | bool | `false` | — | skip leftover tagged remote workers after drive |
| `DISTSSH_WAIT_SCALE` | float > 0 | `1` | — | scales child_reply, go_job, and drive_job waits |
| `DISTSSH_WAIT_CHILD_REPLY` | float >= 0 | `caller default` | — | named wait override |
| `DISTSSH_WAIT_GO_JOB` | float >= 0 | `caller default` | — | named wait override |
| `DISTSSH_WAIT_DRIVE_JOB` | float >= 0 | `caller default` | — | named wait override |
| `DISTSSH_WAIT_STOP_GRACE` | float >= 0 | `caller default` | — | named wait override |
| `DISTSSH_WAIT_SIGINT_GRACE` | float >= 0 | `caller default` | — | named wait override |
| `DISTSSH_WAIT_E2E_STOP` | float >= 0 | `caller default` | — | named wait override |
| `DISTSSH_WAIT_SSH_CONNECT` | float >= 0 | `caller default` | — | named wait override |
| `DISTSSH_WAIT_SSH_AUTH` | float >= 0 | `caller default` | — | named wait override |
| `DISTSSH_WAIT_PEER_SILENT` | float >= 0 | `caller default` | — | named wait override |

## Precedence

Within one scope: **CLI → environment → default**. Per-host Distributed
`bind` overrides come from optional `bind` on each `[[hosts]]` row in a TOML
hosts file (IPv4 literal only; see [Placement](@ref Placement)). `drive`,
`drive`, and `--dry-run` validate every listed host before SSH; invalid `bind`
values fail closed (exit 2 on the CLI, not softened by `--best-effort`).

## Diagnostics

- `--print-config` resolves settings and prints each value with its source, then exits 0 without SSH.
- `--dry-run` prints placement, resolved topology and bind per host (with tunnel), and redacted worker env keys, then exits 0 without SSH.

## Removed CLI names (0.2.0)

| Old flag | Use instead |
|----------|-------------|
| `--unsafe-heterogeneous` | `--unsafe-skip-env-digests` |
| `--allow-mismatch` | `--unsafe-skip-env-digests` (digests only) |
| `-p` / `-pN` (drive, go) | No short alias: `--head-workers N` (drive) or `--head-slots N` (go) |
| `-l`, `--local` | SSH user as `user@host` in a hosts file |
| `-L` | `host:port` in a hosts file or SSH config (no `-L` forwarding flag) |
