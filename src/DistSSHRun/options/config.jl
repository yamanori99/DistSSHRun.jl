# Resolved `RunJobConfig` and diagnostic output.

"""Where one field value came from (avoid naming enum members `Env` / `CLI`)."""
@enum ConfigSource FromCLI FromEnv FromDefault

struct ConfigField
    value::Any
    source::ConfigSource
end

"""Immutable resolved configuration for go / drive / ride."""
struct RunJobConfig
    unsafe_skip_env_digests::ConfigField
    unsafe_expose_port::ConfigField
    unsafe_all_to_all::ConfigField
    unsafe_master_silence_exit::ConfigField
    print_config::ConfigField
    dry_run::ConfigField
    topology::ConfigField
    command::Symbol
end

function _resolve_bool_field(
        key::Symbol;
        cli::Union{Nothing, Bool},
        env::Union{Nothing, String},
        default::Bool,
        env_dict::AbstractDict = ENV,
    )::ConfigField
    if cli !== nothing
        return ConfigField(cli, FromCLI)
    end
    if env !== nothing
        ev = _bool_env(env; env = env_dict)
        ev !== nothing && return ConfigField(ev, FromEnv)
    end
    return ConfigField(default, FromDefault)
end

function _resolve_string_field(
        cli::Union{Nothing, AbstractString},
        env::Union{Nothing, String},
        default::AbstractString;
        env_dict::AbstractDict = ENV,
    )::ConfigField
    if cli !== nothing
        s = strip(String(cli))
        !isempty(s) && return ConfigField(s, FromCLI)
    end
    if env !== nothing && haskey(env_dict, String(env))
        raw = strip(get(env_dict, String(env), ""))
        !isempty(raw) && return ConfigField(raw, FromEnv)
    end
    return ConfigField(String(default), FromDefault)
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

Precedence: CLI, then environment, then default. Per-host scope is reserved
for placement file / machine-file ingest (phase 4).
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
        _resolve_bool_field(
            :unsafe_skip_env_digests;
            cli = cli_unsafe_skip_env_digests,
            env = "DISTSSH_UNSAFE_SKIP_ENV_DIGESTS",
            default = false,
            env_dict = env,
        ),
        _resolve_bool_field(
            :unsafe_expose_port;
            cli = cli_unsafe_expose_port,
            env = "DISTSSH_UNSAFE_EXPOSE_PORT",
            default = false,
            env_dict = env,
        ),
        _resolve_bool_field(
            :unsafe_all_to_all;
            cli = cli_unsafe_all_to_all,
            env = "DISTSSH_UNSAFE_ALL_TO_ALL",
            default = false,
            env_dict = env,
        ),
        _resolve_bool_field(
            :unsafe_master_silence_exit;
            cli = command === :drive ? cli_unsafe_master_silence_exit : false,
            env = command === :drive ? "DISTSSH_UNSAFE_MASTER_SILENCE_EXIT" : nothing,
            default = false,
            env_dict = env,
        ),
        _resolve_bool_field(
            :print_config;
            cli = cli_print_config,
            env = nothing,
            default = false,
            env_dict = env,
        ),
        _resolve_bool_field(
            :dry_run;
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
        field isa ConfigField || continue
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
    )
    println(io, "# dry-run plan ($(cfg.command))")
    println(io, "project = ", repr(canonical_local_path(project)))
    println(io, "topology = ", repr(cfg.topology.value), " (", _config_source_label(cfg.topology.source), ")")
    println(io, "hosts = ", repr(collect(String, hosts)))
    println(io, "placement = ", repr(collect(String, worker_tokens)))
    for row in options_for_command(cfg.command)
        row.unsafe || continue
        field = getfield(cfg, row.key)
        field isa ConfigField || continue
        field.value && println(io, "unsafe ", row.key, " = true")
    end
    println(io, "worker_env_keys (redacted):")
    for (k, _) in ENV
        sk = strip(String(k))
        startswith(sk, "DIST") || startswith(sk, "JULIA") || continue
        println(io, "  ", _redact_env_key(sk))
    end
    println(io, "# bind / per-host overrides: (machine file hook — phase 4)")
    return nothing
end

"""Return true when the caller should exit 0 after printing diagnostics."""
function run_job_config_diagnostic_exit(cfg::RunJobConfig)::Bool
    return cfg.print_config.value || cfg.dry_run.value
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
    if cfg.print_config.value
        print_run_job_config!(stdout, cfg)
    end
    if cfg.dry_run.value
        print_run_job_dry_plan!(
            stdout,
            cfg;
            hosts = hosts,
            worker_tokens = worker_tokens,
            project = project,
        )
    end
    return 0
end

public RunJobConfig, ConfigField, ConfigSource, resolve_run_job_config
public print_run_job_config!, print_run_job_dry_plan!, run_job_config_diagnostic_exit
public resolve_run_job_config_from_parsed, finish_run_job_diagnostics!
