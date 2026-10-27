# Loaded once from DistSSHRun.jl before other drive/runtime fragments.
using Dates
using Distributed

"""Ctrl-C during a drive. Callers `exit(130)` only after process state is restored."""
struct _DriveProcessInterrupt <: Exception end

"""Build a drive error when the driver script path does not exist."""
function drive_script_not_found_message(
        script_path::AbstractString,
        project_root::AbstractString;
        surface::Symbol = :cli,
    )::String
    return explain_script_not_found(script_path, project_root; surface = surface)
end
