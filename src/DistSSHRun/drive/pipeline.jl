# pipeline! — sync → drive → collect.

function _reject_obsolete_pipeline_size_env(env::ProcessEnv)
    for name in ("GB_PER_WORKER", "DISTSSH_SIZE_PROBE", "DISTSSH_INTERNAL_SIZE_PROBE")
        haskey(env, name) || continue
        throw(
            ArgumentError(
                "$name is no longer used by pipeline!; pass explicit parent:N / NAME:N",
            ),
        )
    end
    return nothing
end

function _pipeline_config_driver_path(
        driver::Union{Nothing, AbstractString},
        env::ProcessEnv,
    )::String
    if driver !== nothing
        d = String(strip(driver::AbstractString))
        !isempty(d) && return d
    end
    env_driver = String(strip(get(env, "DRIVER", "")))
    !isempty(env_driver) && return env_driver
    throw(ArgumentError(explain_pipeline_driver_missing(; surface = :api)))
end

"""
    pipeline_config_from_env(; driver=...)

Build [`PipelineConfig`](@ref) from environment variables.

| Variable | Role |
|----------|------|
| `DISTSSH_HOSTS` | Comma-separated placement tokens (`N*host`, …) |
| `DISTSSH_HOSTS_FILE` | Hosts file when the CLI does not set a host list (same precedence as CLI) |
| `DISTSSH_REMOTE_PROJECT_ROOT` | Remote repo root |
| `DISTSSH_PROJECT_ROOT` | Local project root |
| `DRIVER` | Driver script path |
| `JULIA_DISTRIBUTED_EXE` | Remote Julia path (same as CLI `--julia`; `auto` / unset → detect) |
| `DISTSSH_YES` / `DISTSSH_QUIET` / `DISTSSH_PROGRESS` / `DISTSSH_VERBOSE` | Same as CLI `-y` / `-q` / `--progress` / `--verbose` |
"""
function pipeline_config_from_env(;
        driver::Union{Nothing, AbstractString} = nothing,
        env::ProcessEnv = snapshot_process_env(),
    )::PipelineConfig
    _reject_obsolete_pipeline_size_env(env)
    driver_path = _pipeline_config_driver_path(driver, env)
    remote_raw = strip(get(env, "DISTSSH_REMOTE_PROJECT_ROOT", ""))
    project_root = strip(get(env, "DISTSSH_PROJECT_ROOT", ""))
    cli = default_kit_cli_session(env)
    cli.hint_surface = :api
    env_v = _env_verbosity(env)
    return PipelineConfig(
        project = isempty(project_root) ? pwd() : String(project_root),
        workers = placement_source_tokens(cli; keep_counts = true),
        remote = isempty(remote_raw) ? nothing : String(remote_raw),
        hosts_file = nothing,
        quiet = env_v === :quiet,
        verbosity = env_v,
        driver = String(driver_path),
        julia = let j = strip(get(env, "JULIA_DISTRIBUTED_EXE", ""))
            isempty(j) || lowercase(j) == "auto" ? nothing : String(j)
        end,
        process_env = env,
        isolated = false,
        reuse_main = false,
    )
end

"""Build [`DistSSHSession`](@ref) from a pipeline config."""
function kit_session_from_config(config::PipelineConfig)::DistSSHSession
    session = DistSSHSession(
        project = config.project,
        workers = config.tokens,
        head_workers = config.head_workers,
        remote = config.remote,
        hosts_file = config.hosts_file,
        quiet = config.quiet,
        verbosity = config.verbosity,
        env = config.process_env,
    )
    cli = session.cli_session
    config.verbosity !== nothing && (cli.verbosity = config.verbosity)
    cli.quiet = config.quiet
    apply_shared_cli_flags!(cli)
    session.quiet = cli.quiet
    session.verbosity = cli.verbosity
    return session
end

"""Whether [`pipeline!`](@ref) should rsync results back from remotes."""
function resolve_pipeline_collect(config::PipelineConfig, session::DistSSHSession)::Bool
    if config.collect_spec === false
        return false
    end
    isempty(session.hosts) && return false
    return true
end

"""Local directory to collect into."""
function pipeline_collect_root(config::PipelineConfig)::String
    c = config.collect_spec
    if c isa AbstractString
        return canonical_local_path(c)
    end
    if config.output_dir !== nothing
        return canonical_local_path(something(config.output_dir))
    end
    env = strip(get(ENV, "DISTSSH_OUTPUT_DIR", ""))
    if !isempty(env)
        return canonical_local_path(env)
    end
    driver = abspath(config.driver)
    return joinpath(dirname(driver), "output")
end

"""Resolve whether `drive!` should skip git parity (default: yes / skip)."""
function pipeline_skip_hash_check(config::PipelineConfig)::Bool
    if config.skip_hash_check !== nothing
        return config.skip_hash_check == true
    end
    return true
end

"""
    report_pipeline_errors(result::PipelineResult; io=stderr)

Print a short summary when [`pipeline!`](@ref) failed. Returns `result.ok`.
"""
function report_pipeline_errors(result::PipelineResult; io::IO = stderr)::Bool
    result.ok && return true
    _report_run_header!(io, kit_run_result(result))
    _report_sync_host_errors!(io, result.sync)
    if result.drive !== nothing && !result.drive.ok
        println(io, "  drive exit $(result.drive.exit_code)")
    end
    if result.collect !== nothing && !result.collect.ok
        println(io, "  collect exit $(result.collect.exit_code)")
    end
    return false
end

function report_run_errors(result::PipelineResult; io::IO = stderr)::Bool
    return report_pipeline_errors(result; io = io)
end

"""
    pipeline!(driver, workers...; kwargs...) -> PipelineResult
    pipeline!(driver, workers::AbstractVector; kwargs...) -> PipelineResult
    pipeline!(config::PipelineConfig) -> PipelineResult

Run the usual remote workflow: driver, optional collect.
Does not call [`setup!`](@ref); prepare remotes first.

Worker tokens match the CLI (`parent:2`, `1*user@host`). Listed tokens
need `:N`. Keyword `args` are passed to the driver; `remote` is the remote
Confirmations follow CLI flags / `DISTSSH_YES` via `kit_session_from_config`.

```julia
pipeline!(driver, "2*host1"; head_workers=0, args=["8"])
pipeline!(driver, "1*user@h1", "1*user@h2"; remote="/path/to/project", args=["8"], collect=true)
```

Remote hosts default to **no** run-time transfer; prepare with one of
[`setup!`](@ref) `:git_sync` or `:ship_tree`, then `:instantiate` when needed,
before `pipeline!`. `:git_sync` checks out in an existing remote tree; on a
**new** target run [`setup!`](@ref)(`session`, `:git_clone`; `repo=...`) first.
Collect defaults on when remotes are present (`collect=false` to skip).

Returns [`PipelineResult`](@ref); check `result.ok` or use [`report_pipeline_errors`](@ref).
"""
function pipeline!(config::PipelineConfig)::PipelineResult
    return with_kit_invocation_env!(config.process_env) do
        session = kit_session_from_config(config)
        driver = abspath(config.driver)
        if !isfile(driver)
            throw(
                ArgumentError(
                    explain_script_not_found(
                        driver,
                        session.project;
                        surface = hint_surface(session),
                        headline = "driver not found: $driver",
                    ),
                )
            )
        end

        return _with_kit_inproc_run!(:pipeline) do
            _pipeline_run!(config, session, driver)
        end
    end
end

function _pipeline_run!(config::PipelineConfig, session::DistSSHSession, driver::String)
    sync_result = nothing
    # Julia 1.13 `something` throws when every argument is `nothing`.
    # `Some(nothing)` is the documented fallback for "unset".
    lw = something(session.cli_session.head_workers, config.head_workers, Some(nothing))
    plan = if isempty(session.tokens) && lw === nothing
        WorkerPlan()
    else
        worker_plan_from_tokens(
            session.tokens;
            head_workers = lw,
        )
    end

    do_collect = resolve_pipeline_collect(config, session)
    prev_skip = get(ENV, "DISTSSH_SKIP_COLLECT", nothing)
    if do_collect
        ENV["DISTSSH_SKIP_COLLECT"] = "1"
    end
    drive_result = try
        drive!(
            session,
            driver;
            plan = plan,
            args = config.args,
            skip_hash_check = pipeline_skip_hash_check(config),
            output_dir = config.output_dir,
            enable_log = config.enable_log,
            log_dir = config.log_dir,
            package = config.package,
            julia = config.julia,
            ship_id = config.ship_id,
            isolated = config.isolated,
            reuse_main = config.reuse_main,
        )
    finally
        if do_collect
            if prev_skip === nothing
                delete!(ENV, "DISTSSH_SKIP_COLLECT")
            else
                ENV["DISTSSH_SKIP_COLLECT"] = prev_skip
            end
        end
    end
    if !drive_result.ok
        return PipelineResult(
            false,
            sync_result,
            plan,
            drive_result,
            nothing,
            driver;
            failed_step = "drive",
        )
    end

    collect_result = nothing
    if do_collect
        collect_result = collect!(
            session,
            pipeline_collect_root(config);
            merge = config.collect_merge,
            ship_id = config.ship_id,
            best_effort = config.best_effort,
        )
        if !collect_result.ok
            return PipelineResult(
                false,
                sync_result,
                plan,
                drive_result,
                collect_result,
                driver;
                failed_step = "collect",
            )
        end
    end

    return PipelineResult(
        true,
        sync_result,
        plan,
        drive_result,
        collect_result,
        driver,
    )
end

function pipeline!(
        driver::AbstractString,
        workers::AbstractVector{<:AbstractString};
        kwargs...,
    )::PipelineResult
    return pipeline!(PipelineConfig(; driver = driver, workers = workers, kwargs...))
end

function pipeline!(driver::AbstractString; kwargs...)::PipelineResult
    return pipeline!(driver, String[]; kwargs...)
end

function pipeline!(
        driver::AbstractString,
        w1::AbstractString,
        rest::AbstractString...;
        kwargs...,
    )::PipelineResult
    return pipeline!(driver, String[w1, rest...]; kwargs...)
end
