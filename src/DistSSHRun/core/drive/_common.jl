# Loaded once from DistSSHRun.jl before other core/drive fragments.
using Dates
using Distributed

"""
CLI Ctrl-C after the drive frame has restored process state.

`main` turns this into exit code 130. In-process [`drive!`](@ref) rethrows
`InterruptException` or `Base.CancellationRequest` instead, and does not
throw this type.
"""
struct _DriveProcessInterrupt <: Exception end

"""In-process `drive!` after an earlier driver was included into `Main`."""
function drive_reuse_main_required_message()::String
    return "drive!: a driver was already included into Main in this process; " *
        "pass isolated=true or reuse_main=true for another run"
end

"""`isolated=true` and `reuse_main=true` on the same `drive!` call."""
function drive_isolated_reuse_main_conflict_message()::String
    return "drive!: isolated=true and reuse_main=true cannot be used together " *
        "(a child process has no earlier Main driver)"
end

"""`drive!` with `isolated=true` when the session used a hosts file."""
function drive_isolated_hosts_file_message()::String
    return "drive!: isolated=true cannot replay hosts-file placement; list worker tokens explicitly"
end

"""`drive!` with `isolated=true` when `bind_overrides=` is set."""
function drive_isolated_bind_overrides_message()::String
    return "drive!: isolated=true does not accept bind_overrides=; set bind in the hosts file on the child CLI"
end

"""Detached `execute!` with `isolated=` or `reuse_main=`."""
function execute_detached_isolated_reuse_main_message()::String
    return "execute!: detached jobs do not accept isolated= or reuse_main=; the child is already a fresh Julia process"
end

"""Build a drive error when the driver script path does not exist."""
function drive_script_not_found_message(
        script_path::AbstractString,
        project_root::AbstractString;
        surface::Symbol = :cli,
    )::String
    return explain_script_not_found(script_path, project_root; surface = surface)
end
