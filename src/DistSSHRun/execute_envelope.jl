# Typed in-process envelope for [`execute!`](@ref) with keyword parity.

"""
    ExecuteEnvelope

In-process settings for [`execute!`](@ref) (`detached=false`). Fields mirror
accepted `execute!` keywords; use [`execute_envelope`](@ref) to build one.
"""
struct ExecuteEnvelope
    kind::Symbol
    script::String
    tokens::Vector{String}
    output_dir::Union{Nothing, String}
    args::Vector{String}
    project::String
    sync::Union{Nothing, Symbol, Bool}
    julia::Union{Nothing, String}
    source::Union{Nothing, Dict{String, String}}
    quiet::Bool
    verbosity::Union{Nothing, Symbol}
    yes::Bool
    remote::Union{Nothing, String}
    hosts_file::Union{Nothing, String}
    log_dir::Union{Nothing, String}
    enable_log::Bool
    package::Union{Nothing, String}
    require_all_hosts::Bool
    skip_hash_check::Bool
    workers::Union{Nothing, Int}
    repeat::Union{Nothing, Int}
    stdout::Union{Nothing, IO}
    stderr::Union{Nothing, IO}
    job_id::Union{Nothing, String}
    worker_include::Bool
    spi_check::Bool
    unsafe_skip_env_digests::Bool
    unsafe_expose_port::Bool
    unsafe_all_to_all::Bool
    allow_external_symlinks::Bool
    run_id::Union{Nothing, String}
    dir::Union{Nothing, String}
    threads::Union{Integer, AbstractString, Symbol}
    env_allow::Union{Nothing, Symbol, AbstractVector{Symbol}}
    env::Union{Nothing, AbstractDict}
end

function ExecuteEnvelope(
        kind::Symbol,
        script::AbstractString,
        tokens::AbstractVector{<:AbstractString} = String[];
        kwargs...,
    )
    _require_execute_kind!(kind)
    return _execute_envelope_from_kwargs(kind, script, tokens; kwargs...)
end

function _execute_envelope_from_kwargs(
        kind::Symbol,
        script::AbstractString,
        tokens::AbstractVector{<:AbstractString};
        output_dir = nothing,
        args::AbstractVector{<:AbstractString} = String[],
        project::AbstractString = pwd(),
        sync = nothing,
        julia = nothing,
        source = nothing,
        quiet::Bool = false,
        verbosity = nothing,
        yes::Bool = true,
        remote = nothing,
        hosts_file = nothing,
        log_dir = nothing,
        enable_log::Bool = true,
        package = nothing,
        require_all_hosts::Bool = true,
        skip_hash_check::Bool = true,
        workers = nothing,
        repeat = nothing,
        stdout = nothing,
        stderr = nothing,
        job_id = nothing,
        worker_include::Bool = false,
        spi_check::Bool = false,
        unsafe_skip_env_digests::Bool = false,
        unsafe_expose_port::Bool = false,
        unsafe_all_to_all::Bool = false,
        allow_external_symlinks::Bool = false,
        run_id = nothing,
        dir = nothing,
        threads::Union{Integer, AbstractString, Symbol} = 1,
        env_allow = nothing,
        env = nothing,
        detached = false,
        kwargs...,
    )
    for k in keys(kwargs)
        execute_detached_accepts(k; kind) ||
            throw(ArgumentError("execute envelope: unknown keyword $(repr(k))"))
    end
    detached && throw(ArgumentError("execute envelope is for detached=false only"))
    snap = run_id === nothing ? nothing : validate_run_id(run_id)
    return ExecuteEnvelope(
        kind,
        String(script),
        String[String(t) for t in tokens],
        output_dir === nothing ? nothing : String(output_dir),
        String[String(a) for a in args],
        canonical_local_path(String(project)),
        sync,
        julia === nothing ? nothing : String(julia),
        source,
        quiet,
        verbosity,
        yes,
        remote === nothing ? nothing : String(remote),
        hosts_file === nothing ? nothing : String(hosts_file),
        log_dir === nothing ? nothing : String(log_dir),
        enable_log,
        package === nothing ? nothing : String(package),
        require_all_hosts,
        skip_hash_check,
        workers === nothing ? nothing : Int(workers),
        repeat === nothing ? nothing : Int(repeat),
        stdout,
        stderr,
        job_id === nothing ? nothing : String(job_id),
        worker_include,
        spi_check,
        unsafe_skip_env_digests,
        unsafe_expose_port,
        unsafe_all_to_all,
        allow_external_symlinks,
        snap,
        dir === nothing ? nothing : String(dir),
        threads,
        env_allow,
        env,
    )
end

"""Keyword parity constructor for [`execute!`](@ref)."""
execute_envelope(kind, script, tokens; kwargs...) = ExecuteEnvelope(kind, script, tokens; kwargs...)

"""Keywords for [`execute!`](@ref) from an envelope (same filtering as parsed argv)."""
function execute_kwargs_from_envelope(env::ExecuteEnvelope)::Dict{Symbol, Any}
    kw = Dict{Symbol, Any}(
        :output_dir => env.output_dir,
        :args => env.args,
        :julia => env.julia,
        :quiet => env.quiet,
        :verbosity => env.verbosity,
    )
    env.unsafe_skip_env_digests && (kw[:unsafe_skip_env_digests] = true)
    env.unsafe_expose_port && (kw[:unsafe_expose_port] = true)
    env.unsafe_all_to_all && (kw[:unsafe_all_to_all] = true)
    env.run_id !== nothing && (kw[:run_id] = env.run_id)
    env.remote !== nothing && (kw[:remote] = env.remote)
    if env.kind === :go
        env.repeat !== nothing && (kw[:repeat] = env.repeat)
        return kw
    end
    if env.kind === :ride
        env.spi_check && (kw[:spi_check] = true)
        return kw
    end
    kw[:log_dir] = env.log_dir
    kw[:enable_log] = env.enable_log
    kw[:package] = env.package
    kw[:require_all_hosts] = env.require_all_hosts
    kw[:skip_hash_check] = env.skip_hash_check
    env.worker_include && (kw[:worker_include] = true)
    env.workers !== nothing && (kw[:workers] = env.workers)
    return kw
end

function execute!(env::ExecuteEnvelope; detached::Bool = false, kwargs...)
    !isempty(keys(kwargs)) &&
        throw(ArgumentError("execute!(env; …) does not take extra keywords; set fields on the envelope"))
    job_kw = execute_kwargs_from_envelope(env)
    return execute!(
        env.kind,
        env.script,
        env.tokens;
        project = env.project,
        sync = env.sync,
        source = env.source,
        detached = detached,
        dir = env.dir,
        threads = env.threads,
        env_allow = env.env_allow,
        env = env.env,
        pairs(job_kw)...,
    )
end

public ExecuteEnvelope, execute_envelope, execute_kwargs_from_envelope
