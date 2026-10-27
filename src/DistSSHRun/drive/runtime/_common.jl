# Loaded once from DistSSHRun.jl before other drive/runtime fragments.
using Dates
using Distributed

"""
CLI Ctrl-C after the drive frame has restored process state.

`main` turns this into exit code 130. In-process [`drive!`](@ref) rethrows
`InterruptException` or `Base.CancellationRequest` instead, and does not
throw this type.
"""
struct _DriveProcessInterrupt <: Exception end

"""Build a drive error when the driver script path does not exist."""
function drive_script_not_found_message(
        script_path::AbstractString,
        project_root::AbstractString;
        surface::Symbol = :cli,
    )::String
    return explain_script_not_found(script_path, project_root; surface = surface)
end
