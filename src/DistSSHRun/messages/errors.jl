# Stable DSSH-E### error codes and typed exceptions for user-facing failures.

"""Stable error metadata (code is never reused)."""
struct ErrorSpec
    code::String
    anchor::String
    title::String
end

const _DSSH_ERROR_SPECS = (
    removed_cli_flag = ErrorSpec("DSSH-E001", "removed-cli-flag", "Removed CLI flag"),
    unknown_cli_option = ErrorSpec("DSSH-E002", "unknown-cli-option", "Unknown CLI option"),
    conflicting_verbosity_env = ErrorSpec(
        "DSSH-E003",
        "conflicting-verbosity-env",
        "Conflicting verbosity environment variables",
    ),
    hosts_file_missing = ErrorSpec("DSSH-E010", "hosts-file-missing", "Hosts file not found"),
    hosts_file_empty = ErrorSpec("DSSH-E011", "hosts-file-empty", "Hosts file has no hosts"),
    placement_token_invalid = ErrorSpec(
        "DSSH-E020",
        "placement-token-invalid",
        "Invalid placement token",
    ),
    topology_bind_rejected = ErrorSpec(
        "DSSH-E030",
        "topology-bind-rejected",
        "Topology or bind rejected",
    ),
    identity_env_mismatch = ErrorSpec(
        "DSSH-E040",
        "identity-env-mismatch",
        "Worker environment mismatch",
    ),
)

const ERROR_REGISTRY = Dict{Symbol, ErrorSpec}(pairs(_DSSH_ERROR_SPECS))

public ERROR_REGISTRY, ErrorSpec, DistSSHError
public error_spec, error_code

abstract type DistSSHError <: Exception end

struct DistSSHErrorDetail
    what::String
    where_s::Union{Nothing, String}
    why::Union{Nothing, String}
    fix::Union{Nothing, String}
    repro::Union{Nothing, String}
end

struct TypedDistSSHError <: DistSSHError
    kind::Symbol
    detail::DistSSHErrorDetail
end

function error_spec(kind::Symbol)::ErrorSpec
    spec = get(_DSSH_ERROR_SPECS, kind, nothing)
    spec === nothing &&
        throw(ArgumentError("unknown DistSSH error kind $(repr(kind))"))
    return spec
end

error_code(kind::Symbol)::String = error_spec(kind).code

function _print_error_block(io::IO, detail::DistSSHErrorDetail, code::String, title::String)
    print(io, "ERROR [", code, "]: ", title)
    print(io, '\n', "What: ", detail.what)
    if detail.where_s !== nothing
        print(io, '\n', "Where: ", detail.where_s)
    end
    if detail.why !== nothing
        print(io, '\n', "Why: ", detail.why)
    end
    if detail.fix !== nothing
        print(io, '\n', "Fix: ", detail.fix)
    end
    if detail.repro !== nothing
        print(io, '\n', "Reproduce: ", detail.repro)
    end
    return nothing
end

function Base.showerror(io::IO, err::TypedDistSSHError)
    spec = error_spec(err.kind)
    return _print_error_block(io, err.detail, spec.code, spec.title)
end

"""Build a removed-flag error (`DSSH-E001`)."""
function removed_cli_flag_error(;
        flag::AbstractString,
        replacement::AbstractString,
        surface::AbstractString = "command",
    )::TypedDistSSHError
    detail = DistSSHErrorDetail(
        string(flag, " was removed"),
        surface,
        "The flag name changed in 0.2.0 with no alias.",
        string("Use ", replacement, " instead."),
        nothing,
    )
    return TypedDistSSHError(:removed_cli_flag, detail)
end

"""Raise `TypedDistSSHError` as `ArgumentError` text for existing CLI handlers."""
function throw_removed_cli_flag!(flag::AbstractString, replacement::AbstractString; surface::AbstractString = "command")
    err = removed_cli_flag_error(; flag, replacement, surface)
    throw(ArgumentError(sprint(showerror, err)))
end

"""Map a `DistSSHError` to CLI exit code (usage vs runtime)."""
function cli_exit_code(err::DistSSHError)::Int
    return err isa TypedDistSSHError && err.kind === :unknown_cli_option ? 2 : 1
end

public removed_cli_flag_error, throw_removed_cli_flag!, cli_exit_code
