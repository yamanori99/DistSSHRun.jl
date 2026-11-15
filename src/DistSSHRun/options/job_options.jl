# Typed per-job options: drive runs and collect-only jobs.

"""Immutable drive job options (shared RunJobConfig plus drive-only flags)."""
struct DriveJobOptions
    config::RunJobConfig
    skip_hash_check::Bool
    require_all_hosts::Bool
    worker_include::Bool
    enable_log::Bool
    isolated::Bool
    default_workers::Union{Nothing, Int}
    explicit_package::Union{Nothing, String}
    run_id::Union{Nothing, String}
    deploy_root::Union{Nothing, String}
    julia::Union{Nothing, String}
end

"""Collect-only job options (`collect!`, `drive --collect-*`)."""
struct CollectJobOptions
    merge::Bool
    strict::Bool
    remote_root::Union{Nothing, String}
    run_id::Union{Nothing, String}
    julia::Union{Nothing, String}
end

function _parsed_optional_string(parsed, key::Symbol)::Union{Nothing, String}
    hasproperty(parsed, key) || return nothing
    v = getproperty(parsed, key)
    (v === nothing || v === missing) && return nothing
    s = strip(String(v))
    isempty(s) && return nothing
    return s
end

"""Build [`DriveJobOptions`](@ref) from a drive `parse_drive_args` NamedTuple."""
function drive_job_options_from_parsed(parsed)::DriveJobOptions
    cfg = resolve_run_job_config_from_parsed(parsed; command = :drive)
    snap = get(parsed, :run_id, nothing)
    snap = snap === nothing ? nothing : validate_run_id(snap)
    dw = get(parsed, :default_workers, nothing)
    dw = dw === nothing ? nothing : Int(dw)
    return DriveJobOptions(
        cfg,
        get(parsed, :skip_hash_check, true),
        get(parsed, :require_all_hosts, true),
        get(parsed, :worker_include, false),
        get(parsed, :enable_log, true),
        get(parsed, :isolated, false) === true,
        dw,
        _parsed_optional_string(parsed, :explicit_package),
        snap,
        _parsed_optional_string(parsed, :deploy_root),
        _parsed_optional_string(parsed, :julia),
    )
end

"""Build [`CollectJobOptions`](@ref) from drive collect argv shape or `collect!` kwargs."""
function collect_job_options(;
        merge::Bool = false,
        strict::Bool = false,
        remote_root::Union{Nothing, AbstractString} = nothing,
        run_id::Union{Nothing, AbstractString} = nothing,
        julia::Union{Nothing, AbstractString} = nothing,
    )::CollectJobOptions
    rr = remote_root === nothing ? nothing : strip(String(remote_root))
    rr !== nothing && isempty(rr) && (rr = nothing)
    snap = run_id === nothing ? nothing : validate_run_id(run_id)
    jl = julia === nothing ? nothing : let s = strip(String(julia))
            isempty(s) || lowercase(s) == "auto" ? nothing : s
    end
    return CollectJobOptions(merge, strict, rr, snap, jl)
end

"""Build collect options from drive `parse_drive_args` collect branch."""
function collect_job_options_from_parsed(parsed)::CollectJobOptions
    merge = something(get(parsed, :collect_overwrite, nothing), false)
    strict = get(parsed, :collect_strict, false)
    return collect_job_options(;
        merge = merge,
        strict = strict,
        remote_root = get(parsed, :deploy_root, nothing),
        run_id = get(parsed, :run_id, nothing),
        julia = get(parsed, :julia, nothing),
    )
end

public CollectJobOptions, DriveJobOptions
public collect_job_options, collect_job_options_from_parsed, drive_job_options_from_parsed
