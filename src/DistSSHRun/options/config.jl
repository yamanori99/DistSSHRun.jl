# Resolved `RunJobConfig` and diagnostic output.

"""Where one field value came from (avoid naming enum members `Env` / `CLI`)."""
@enum ConfigSource FromCLI FromEnv FromDefault

struct BoolConfigField
    value::Bool
    source::ConfigSource
end

struct StringConfigField
    value::String
    source::ConfigSource
end

"""Immutable resolved configuration for go / drive / ride."""
struct RunJobConfig
    unsafe_skip_env_digests::BoolConfigField
    unsafe_expose_port::BoolConfigField
    unsafe_all_to_all::BoolConfigField
    unsafe_master_silence_exit::BoolConfigField
    print_config::BoolConfigField
    dry_run::BoolConfigField
    topology::StringConfigField
    command::Symbol
end

function _resolve_bool_field(;
        cli::Union{Nothing, Bool},
        env::Union{Nothing, String},
        default::Bool,
        env_dict::AbstractDict = ENV,
    )::BoolConfigField
    if cli !== nothing
        return BoolConfigField(cli, FromCLI)
    end
    if env !== nothing
        ev = _bool_env(env; env = env_dict)
        ev !== nothing && return BoolConfigField(ev, FromEnv)
    end
    return BoolConfigField(default, FromDefault)
end

function _resolve_string_field(
        cli::Union{Nothing, AbstractString},
        env::Union{Nothing, String},
        default::AbstractString;
        env_dict::AbstractDict = ENV,
    )::StringConfigField
    if cli !== nothing
        s = strip(String(cli))
        !isempty(s) && return StringConfigField(s, FromCLI)
    end
    if env !== nothing && haskey(env_dict, String(env))
        raw = strip(get(env_dict, String(env), ""))
        !isempty(raw) && return StringConfigField(raw, FromEnv)
    end
    return StringConfigField(String(default), FromDefault)
end

"""
    resolve_run_job_config(;
        command,
        cli_unsafe_skip_env_digests = nothing,
        cli_unsafe_expose_port = nothing,
        cli_unsafe_all_to_all = nothing,
        cli_unsafe_master_silence_exit = nothing,
        cli_print_config = nothing,
        cli_dry_run = nothing,
        cli_topology = nothing,
        env = ENV,
    ) -> RunJobConfig

Precedence: CLI, then environment, then default. Per-host `bind` comes from
TOML `[[hosts]]` rows when the host list uses `--hosts-file` or
`DISTSSH_HOSTS_FILE`.
"""
function resolve_run_job_config(;
        command::Symbol,
        cli_unsafe_skip_env_digests::Union{Nothing, Bool} = nothing,
        cli_unsafe_expose_port::Union{Nothing, Bool} = nothing,
        cli_unsafe_all_to_all::Union{Nothing, Bool} = nothing,
        cli_unsafe_master_silence_exit::Union{Nothing, Bool} = nothing,
        cli_print_config::Union{Nothing, Bool} = nothing,
        cli_dry_run::Union{Nothing, Bool} = nothing,
        cli_topology::Union{Nothing, AbstractString} = nothing,
        env::AbstractDict{<:Any, <:Any} = ENV,
    )::RunJobConfig
    command in RUN_JOB_COMMANDS ||
        throw(ArgumentError("resolve_run_job_config: unsupported command $(repr(command))"))
    return RunJobConfig(
        _resolve_bool_field(;
            cli = cli_unsafe_skip_env_digests,
            env = "DISTSSH_UNSAFE_SKIP_ENV_DIGESTS",
            default = false,
            env_dict = env,
        ),
        _resolve_bool_field(;
            cli = cli_unsafe_expose_port,
            env = "DISTSSH_UNSAFE_EXPOSE_PORT",
            default = false,
            env_dict = env,
        ),
        _resolve_bool_field(;
            cli = cli_unsafe_all_to_all,
            env = "DISTSSH_UNSAFE_ALL_TO_ALL",
            default = false,
            env_dict = env,
        ),
        _resolve_bool_field(;
            cli = command === :drive ? cli_unsafe_master_silence_exit : false,
            env = command === :drive ? "DISTSSH_UNSAFE_MASTER_SILENCE_EXIT" : nothing,
            default = false,
            env_dict = env,
        ),
        _resolve_bool_field(;
            cli = cli_print_config,
            env = nothing,
            default = false,
            env_dict = env,
        ),
        _resolve_bool_field(;
            cli = cli_dry_run,
            env = nothing,
            default = false,
            env_dict = env,
        ),
        _resolve_string_field(
            cli_topology,
            "DISTSSH_TOPOLOGY",
            "auto";
            env_dict = env,
        ),
        command,
    )
end

function _config_source_label(src::ConfigSource)::String
    return src === FromCLI ? "cli" : src === FromEnv ? "env" : "default"
end

function _config_field_name(field::Symbol)::String
    return string(field)
end

"""Print resolved config fields and sources to `io`."""
function print_run_job_config!(io::IO, cfg::RunJobConfig)
    println(io, "# resolved run config ($(cfg.command))")
    for name in fieldnames(RunJobConfig)
        name === :command && continue
        field = getfield(cfg, name)
        if field isa BoolConfigField
            println(
                io,
                _config_field_name(name),
                " = ",
                repr(field.value),
                " (",
                _config_source_label(field.source),
                ")",
            )
        elseif field isa StringConfigField
            println(
                io,
                _config_field_name(name),
                " = ",
                repr(field.value),
                " (",
                _config_source_label(field.source),
                ")",
            )
        end
    end
    return nothing
end

const _REDACTED_ENV_PREFIXES = ("DISTRIBUTED_", "DISTSSH_", "SSH_", "JULIA_")

function _redact_env_key(key::AbstractString)::String
    k = String(key)
    for pref in _REDACTED_ENV_PREFIXES
        startswith(k, pref) || continue
        return k
    end
    return string(k, "=…")
end

"""
    print_run_job_dry_plan!(io, cfg::RunJobConfig; hosts, worker_tokens, project)

Print hosts, placement tokens, topology, and redacted per-worker env keys.
No SSH.
"""
function print_run_job_dry_plan!(
        io::IO,
        cfg::RunJobConfig;
        hosts::AbstractVector{<:AbstractString},
        worker_tokens::AbstractVector{<:AbstractString},
        project::AbstractString,
        head_workers::Union{Nothing, Integer} = nothing,
        head_slots::Union{Nothing, Integer} = nothing,
        hosts_source::Union{Nothing, Symbol} = nothing,
        go_implicit_no_hosts::Bool = false,
        bind_overrides::AbstractDict{<:AbstractString, <:AbstractString} = Dict{String, String}(),
    )
    println(io, "# dry-run plan ($(cfg.command))")
    println(io, "project = ", repr(canonical_local_path(project)))
    println(io, "topology = ", repr(cfg.topology.value), " (", _config_source_label(cfg.topology.source), ")")
    if hosts_source !== nothing
        println(io, "hosts_source = ", repr(placement_host_source_label(hosts_source)))
    end
    println(io, "hosts = ", repr(collect(String, hosts)))
    println(io, "placement = ", repr(collect(String, worker_tokens)))
    if cfg.command === :go
        n = head_slots === nothing ? 0 : Int(head_slots)
        println(io, "head_slots = $n")
        if go_implicit_no_hosts
            println(io, "head = ", repr(format_kit_go_implicit_head_slot()))
        elseif n > 0
            println(io, "head = ", repr(format_kit_head_placement(n, "slots")))
        end
    else
        n = head_workers === nothing ? 0 : Int(head_workers)
        println(io, "head_workers = $n")
        n > 0 && println(io, "head = ", repr(format_kit_head_placement(n, "workers")))
    end
    for row in options_for_command(cfg.command)
        row.unsafe || continue
        field = getfield(cfg, row.key)
        field isa BoolConfigField || continue
        field.value && println(io, "unsafe ", row.key, " = true")
    end
    println(io, "worker_env_keys (redacted):")
    for (k, _) in ENV
        sk = strip(String(k))
        startswith(sk, "DIST") || startswith(sk, "JULIA") || continue
        println(io, "  ", _redact_env_key(sk))
    end
    tunnel = ssh_tunnel_enabled()
    ssh_hosts = String[launch_bind_host_key(h) for h in hosts]
    plans = validate_all_host_launch_plans!(
        ssh_hosts,
        bind_overrides;
        tunnel = tunnel,
        unsafe_expose_port = cfg.unsafe_expose_port.value,
        unsafe_all_to_all = cfg.unsafe_all_to_all.value,
        topology_setting = cfg.topology.value,
    )
    println(io, "launch (per host):")
    for plan in plans
        println(io, "  ", format_host_launch_plan_line(plan))
    end
    return nothing
end

"""Return true when the caller should exit 0 after printing diagnostics."""
function run_job_config_diagnostic_exit(cfg::RunJobConfig)::Bool
    return cfg.print_config.value || cfg.dry_run.value
end

"""Map a parsed CLI/API keyword (`missing` = omit) into `resolve_run_job_config` CLI input."""
function cli_optional_bool(v)::Union{Nothing, Bool}
    v === missing && return nothing
    v isa Bool || throw(ArgumentError("cli_optional_bool: expected Bool or missing, got $(typeof(v))"))
    return v
end

function _cli_bool(parsed, key::Symbol)::Union{Nothing, Bool}
    hasproperty(parsed, key) || return nothing
    v = getproperty(parsed, key)
    v === missing && return nothing
    v === nothing && return nothing
    v isa Bool || return nothing
    return v
end

"""Build [`RunJobConfig`](@ref) from a go / drive / ride parse result."""
function resolve_run_job_config_from_parsed(parsed; command::Symbol)::RunJobConfig
    return resolve_run_job_config(;
        command,
        cli_unsafe_skip_env_digests = _cli_bool(parsed, :unsafe_skip_env_digests),
        cli_unsafe_expose_port = _cli_bool(parsed, :unsafe_expose_port),
        cli_unsafe_all_to_all = _cli_bool(parsed, :unsafe_all_to_all),
        cli_unsafe_master_silence_exit = _cli_bool(parsed, :unsafe_master_silence_exit),
        cli_print_config = _cli_bool(parsed, :print_config),
        cli_dry_run = _cli_bool(parsed, :dry_run),
    )
end

"""
    finish_run_job_diagnostics!(parsed; command, project, hosts, worker_tokens) -> Union{Nothing, Int}

When `--print-config` or `--dry-run` is set, print and return `0`. Otherwise `nothing`.
"""
function finish_run_job_diagnostics!(
        parsed;
        command::Symbol,
        project::AbstractString,
        hosts::AbstractVector{<:AbstractString},
        worker_tokens::AbstractVector{<:AbstractString},
    )::Union{Nothing, Int}
    cfg = resolve_run_job_config_from_parsed(parsed; command)
    run_job_config_diagnostic_exit(cfg) || return nothing
    cli = getproperty(parsed, :cli_session)
    hosts_vec = collect(String, hosts)
    hosts_source = isempty(hosts_vec) ? :none : placement_host_source(cli)
    if cfg.dry_run.value
        override = kit_distssh_hosts_override_notice(cli)
        override !== nothing && println(stdout, override)
    elseif !cfg.print_config.value
        writeln_kit_resolved_hosts!(cli, hosts_vec; quiet = cli.quiet)
    end
    if cfg.print_config.value
        print_run_job_config!(stdout, cfg)
    end
    go_ls, go_implicit = if command === :go
        resolve_go_head_slots(hosts_vec, cli.head_slots)
    else
        (0, false)
    end
    planned_ssh = String[launch_bind_host_key(h) for h in hosts]
    bind_overrides = try
        hosts_file_bind_overrides(
            cli;
            bind_overrides = get(parsed, :bind_overrides, Dict{String, String}()),
            planned_hosts = planned_ssh,
            command = command,
        )
    catch e
        e isa ArgumentError || rethrow()
        cli.hint_surface === :cli &&
            throw(DistSSHBase.CliUsageError(_bind_config_cli_message(e.msg)))
        rethrow()
    end
    if cfg.dry_run.value
        resolved_workers = if command === :drive && hasproperty(parsed, :head_workers)
            Int(getproperty(parsed, :head_workers))
        elseif command === :ride || command === :drive
            something(cli.head_workers, 0)
        else
            nothing
        end
        print_run_job_dry_plan!(
            stdout,
            cfg;
            hosts = hosts,
            worker_tokens = worker_tokens,
            project = project,
            head_workers = command === :go ? nothing : resolved_workers,
            head_slots = command === :go ? go_ls : nothing,
            hosts_source = hosts_source,
            go_implicit_no_hosts = go_implicit,
            bind_overrides = bind_overrides,
        )
    end
    return 0
end

public BoolConfigField, ConfigSource, RunJobConfig, StringConfigField
public finish_run_job_diagnostics!, print_run_job_config!, print_run_job_dry_plan!
public cli_optional_bool, resolve_run_job_config, resolve_run_job_config_from_parsed
public run_job_config_diagnostic_exit
