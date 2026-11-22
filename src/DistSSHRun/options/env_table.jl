# User-facing `DISTSSH_*` variables. Hand-offs use `DISTSSH_INTERNAL_*`.

"""One documented environment variable (options.md)."""
struct EnvRow
    name::String
    kind::String
    default::String
    cli::String
    help::String
end

function user_env_table()::Vector{EnvRow}
    return EnvRow[
        EnvRow("DISTSSH_QUIET", "bool", "unset", "--quiet", "hide terminal detail"),
        EnvRow("DISTSSH_PROGRESS", "bool", "unset", "--progress", "live status"),
        EnvRow("DISTSSH_VERBOSE", "bool", "unset", "--verbose", "full detail"),
        EnvRow("DISTSSH_YES", "bool", "unset", "-y / --yes", "non-interactive confirm where allowed"),
        EnvRow("DISTSSH_HOSTS", "string", "unset", "--hosts", "CSV of N*host tokens"),
        EnvRow("DISTSSH_HOSTS_FILE", "path", "unset", "--hosts-file", "hosts file path"),
        EnvRow("DISTSSH_HEAD_WORKERS", "int", "unset", "--head-workers", "LocalManager workers (drive)"),
        EnvRow("DISTSSH_JOBS", "int >= 1", "1", "—", "max concurrent host and go-slot SSH jobs"),
        EnvRow("DISTSSH_REQUIRE_ALL_HOSTS", "bool", "false", "--require-all-hosts", "fail if any listed host is missing"),
        EnvRow("DISTSSH_BEST_EFFORT", "bool", "false", "--best-effort", "continue after a host failure where allowed"),
        EnvRow("DISTSSH_UNSAFE_SKIP_ENV_DIGESTS", "bool", "false", "--unsafe-skip-env-digests", "waive Manifest/Project digest checks"),
        EnvRow("DISTSSH_UNSAFE_EXPOSE_PORT", "bool", "false", "--unsafe-expose-port", "allow non-loopback Distributed bind"),
        EnvRow("DISTSSH_UNSAFE_ALL_TO_ALL", "bool", "false", "--unsafe-all-to-all", "allow worker-to-worker connections"),
        EnvRow("DISTSSH_UNSAFE_MASTER_SILENCE_EXIT", "bool", "false", "--unsafe-master-silence-exit", "worker self-exit when the controller is silent"),
        EnvRow("DISTSSH_TOPOLOGY", "string", "auto", "—", "Distributed topology: auto or master_worker"),
        EnvRow("DISTSSH_SSH_TUNNEL", "bool", "true", "—", "SSH tunnel for worker connections"),
        EnvRow("DISTSSH_SSH_OPTS", "string", "unset", "—", "extra OpenSSH tokens (shell-split)"),
        EnvRow("DISTSSH_PROJECT_ROOT", "path", "pwd", "—", "local project root"),
        EnvRow("DISTSSH_REMOTE_PROJECT_ROOT", "path", "layout default", "--deploy-root", "remote project root"),
        EnvRow("DISTSSH_OUTPUT_DIR", "path", "command default", "--output-dir", "output / slot directory"),
        EnvRow("DISTSSH_RUN_DIR", "path", "allocated", "—", "this execution's run directory"),
        EnvRow("DISTSSH_COLLECT_DIRS", "path list", "unset", "—", "extra collect trees (colon-separated)"),
        EnvRow("DISTSSH_SKIP_COLLECT", "bool", "false", "—", "skip post-run collect"),
        EnvRow("DISTSSH_HEARTBEAT_DEADLINE_SEC", "float > 0", "unset", "—", "required when master-silence-exit is on"),
        EnvRow("DISTSSH_HEARTBEAT_INTERVAL_SEC", "float > 0", "30", "—", "heartbeat ping interval"),
        EnvRow("DISTSSH_INIT_DELAY_SEC", "float > 0", "5", "—", "SSH worker init delay; local-only is 0"),
        EnvRow("DISTSSH_PING_RETRIES", "int >= 1", "6", "—", "worker ping attempts during drive init"),
        EnvRow("DISTSSH_JOB_ID", "string", "unset", "—", "job id for tagged remote processes"),
        EnvRow("DISTSSH_JOB_SEED", "uint64 hex", "unset", "—", "controller job seed"),
        EnvRow("DISTSSH_WORKER_RANK", "int", "unset", "—", "worker rank (set on the slot)"),
        EnvRow("DISTSSH_WORKER_SEED", "uint64 hex", "unset", "—", "per-worker seed (set on the slot)"),
        EnvRow("DISTSSH_SHIP_WARN_FILE_BYTES", "int", "104857600", "—", "warn when one shipped file exceeds this"),
        EnvRow("DISTSSH_SHIP_WARN_TOTAL_BYTES", "int", "unset", "—", "warn when the shipped total exceeds this"),
        EnvRow("DISTSSH_PROGRESS_BG", "string", "unset", "—", "progress accent: light or dark"),
        EnvRow("DISTSSH_BLAS_THREADS", "int >= 1", "unset", "—", "OpenBLAS/OMP threads on workers"),
        EnvRow("DISTSSH_SKIP_GLOBAL_WORKER_PKILL", "bool", "false", "—", "skip drive leftover tagged remote pkill"),
        EnvRow("DISTSSH_WAIT_SCALE", "float > 0", "1", "—", "scales child_reply, go_job, and drive_job waits"),
        EnvRow("DISTSSH_WAIT_CHILD_REPLY", "float >= 0", "caller default", "—", "named wait override"),
        EnvRow("DISTSSH_WAIT_GO_JOB", "float >= 0", "caller default", "—", "named wait override"),
        EnvRow("DISTSSH_WAIT_DRIVE_JOB", "float >= 0", "caller default", "—", "named wait override"),
        EnvRow("DISTSSH_WAIT_STOP_GRACE", "float >= 0", "caller default", "—", "named wait override"),
        EnvRow("DISTSSH_WAIT_SIGINT_GRACE", "float >= 0", "caller default", "—", "named wait override"),
        EnvRow("DISTSSH_WAIT_E2E_STOP", "float >= 0", "caller default", "—", "named wait override"),
        EnvRow("DISTSSH_WAIT_SSH_CONNECT", "float >= 0", "caller default", "—", "named wait override"),
        EnvRow("DISTSSH_WAIT_SSH_AUTH", "float >= 0", "caller default", "—", "named wait override"),
        EnvRow("DISTSSH_WAIT_PEER_SILENT", "float >= 0", "caller default", "—", "named wait override"),
    ]
end

function user_env_names()::Set{String}
    return Set{String}(row.name for row in user_env_table())
end

function generated_env_options_markdown()::String
    io = IOBuffer()
    println(io, "# [Run options (generated from the option table)](@id Options)")
    println(io)
    println(io, "The authoritative definitions live in `src/DistSSHRun/options/table.jl`")
    println(io, "and `src/DistSSHRun/options/env_table.jl`.")
    println(io, "Help text for `go` and `drive` is generated from the option rows.")
    println(io, "CI fails when `--help` and this page drift from those tables.")
    println(io)
    println(io, "## Shared run-job flags")
    println(io)
    println(io, "| Key | CLI | Environment | Default | Unsafe |")
    println(io, "|-----|-----|-------------|---------|--------|")
    for row in run_option_table()
        :go in row.commands && :drive in row.commands || continue
        cli = row.cli === nothing ? "—" : "`$(row.cli)`"
        env = row.env === nothing ? "—" : "`$(row.env)`"
        unsafe = row.unsafe ? "yes" : "no"
        println(io, "| `$(row.key)` | $(cli) | $(env) | `$(row.default)` | $(unsafe) |")
    end
    println(io)
    println(io, "## Drive-only flags")
    println(io)
    println(io, "| Key | CLI | Environment | Default | Unsafe |")
    println(io, "|-----|-----|-------------|---------|--------|")
    for row in run_option_table()
        row.commands == (:drive,) || continue
        cli = row.cli === nothing ? "—" : "`$(row.cli)`"
        env = row.env === nothing ? "—" : "`$(row.env)`"
        unsafe = row.unsafe ? "yes" : "no"
        println(io, "| `$(row.key)` | $(cli) | $(env) | `$(row.default)` | $(unsafe) |")
    end
    println(io)
    println(io, "## Environment variables")
    println(io)
    println(io, "User-facing names. A parent-to-child hand-off uses `DISTSSH_INTERNAL_*`")
    println(io, "and is not an option. Test doubles are injected from `test/` and are not read as options.")
    println(io, "An old Distributed-prefix name is an error that names the DistSSH replacement.")
    println(io, "A numeric or boolean value that does not parse is an error that names the variable.")
    println(io)
    println(io, "| Name | Type | Default | CLI | Meaning |")
    println(io, "|------|------|---------|-----|---------|")
    for row in user_env_table()
        cli = row.cli == "—" ? "—" : "`$(row.cli)`"
        println(
            io,
            "| `$(row.name)` | $(row.kind) | `$(row.default)` | $(cli) | $(row.help) |",
        )
    end
    println(io)
    println(io, "## Precedence")
    println(io)
    println(io, "Within one scope: **CLI → environment → default**. Per-host Distributed")
    println(io, "`bind` overrides come from optional `bind` on each `[[hosts]]` row in a TOML")
    println(io, "hosts file (IPv4 literal only; see [Placement](@ref Placement)). `drive`,")
    println(io, "`drive`, and `--dry-run` validate every listed host before SSH; invalid `bind`")
    println(io, "values fail closed (exit 2 on the CLI, not softened by `--best-effort`).")
    println(io)
    println(io, "## Diagnostics")
    println(io)
    println(io, "- `--print-config` resolves settings and prints each value with its source, then exits 0 without SSH.")
    println(io, "- `--dry-run` prints placement, resolved topology and bind per host (with tunnel), and redacted worker env keys, then exits 0 without SSH.")
    println(io)
    println(io, "## Removed CLI names (0.2.0)")
    println(io)
    println(io, "| Old flag | Use instead |")
    println(io, "|----------|-------------|")
    println(io, "| `--unsafe-heterogeneous` | `--unsafe-skip-env-digests` |")
    println(io, "| `--allow-mismatch` | `--unsafe-skip-env-digests` (digests only) |")
    println(io, "| `-p` / `-pN` (drive, go) | No short alias: `--head-workers N` (drive) or `--head-slots N` (go) |")
    println(io, "| `-l`, `--local` | SSH user as `user@host` in a hosts file |")
    println(io, "| `-L` | `host:port` in a hosts file or SSH config (no `-L` forwarding flag) |")
    return String(take!(io))
end

# Not `public`: the cluster-manager freeze is the option table, not this list.
