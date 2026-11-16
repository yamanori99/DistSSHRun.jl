# Typed launch outcomes (public surface frozen for 0.2.0).

"""Why a planned worker did not become usable (join or load)."""
@enum WorkerLaunchOutcome begin
    Joined
    FailedToConnect
    FailedToLoad
end

"""One host (or local head) where planned workers did not all become usable."""
struct HostLaunchFailure
    host::String
    requested::Int
    joined::Int
    outcome::WorkerLaunchOutcome
    reason::String
end

"""
Summary of a worker launch: planned total, joined total, and per-host failures.

Field access uses [`launch_report_planned`](@ref) and friends. Do not rely on
struct positional construction; it is not public API.
"""
struct LaunchReport
    planned_workers::Int
    joined_workers::Int
    failures::Vector{HostLaunchFailure}
end

"""Planned worker count from a [`LaunchReport`](@ref) (sum of ranks in the launch plan)."""
launch_report_planned(r::LaunchReport)::Int = r.planned_workers

"""Workers that joined and passed load verification in this launch."""
launch_report_joined(r::LaunchReport)::Int = r.joined_workers

"""Per-host rows where joined count fell short or load failed (defensive copy)."""
launch_report_failures(r::LaunchReport)::Vector{HostLaunchFailure} = copy(r.failures)

function _host_launch_failure(f::HostLaunchFailure)
    return (f.host, f.requested, f.joined, f.outcome, f.reason)
end

"""
`true` when every planned worker joined and no host failure rows were recorded.

Strict drive/ride treat a false result as [`LaunchIncompleteError`](@ref) when
`best_effort` is false.
"""
function launch_report_usable(r::LaunchReport)::Bool
    return isempty(r.failures) && r.joined_workers == r.planned_workers
end

"""Thrown when launch did not place all planned workers and `best_effort` is false."""
struct LaunchIncompleteError <: Exception
    report::LaunchReport
end

function Base.showerror(io::IO, e::LaunchIncompleteError)
    r = e.report
    print(io, "Launch incomplete: planned $(r.planned_workers) workers, joined $(r.joined_workers)")
    isempty(r.failures) && return
    print(io, ":")
    for f in r.failures
        print(io, "\n  ", f.host, ": wanted ", f.requested, ", joined ", f.joined, " (", f.outcome, ")")
        isempty(f.reason) || print(io, " — ", f.reason)
    end
    print(io, "\nPass best_effort=true or CLI --best-effort to continue with partial workers.")
    return
end

function _merge_launch_report!(
        acc::LaunchReport,
        host::AbstractString,
        requested::Integer,
        joined::Integer,
        outcome::WorkerLaunchOutcome,
        reason::AbstractString,
    )::LaunchReport
    req = Int(requested)
    got = Int(joined)
    planned = acc.planned_workers
    joined_total = acc.joined_workers + got
    failures = HostLaunchFailure[]
    if outcome !== Joined || got < req
        oc = outcome === Joined ? FailedToConnect : outcome
        push!(
            failures,
            HostLaunchFailure(String(host), req, got, oc, String(strip(String(reason)))),
        )
    end
    return LaunchReport(planned, joined_total, vcat(acc.failures, failures))
end

function _empty_launch_report(planned::Integer)::LaunchReport
    return LaunchReport(Int(planned), 0, HostLaunchFailure[])
end

function enforce_launch_contract!(report::LaunchReport; best_effort::Bool)::LaunchReport
    best_effort && return report
    launch_report_usable(report) || throw(LaunchIncompleteError(report))
    return report
end
