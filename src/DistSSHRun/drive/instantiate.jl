# instantiate! — Pkg.instantiate on remotes (same core as `setup instantiate`).

"""
    instantiate!(session::KitSession; julia="auto") -> SyncResult

Run `Pkg.instantiate` on each SSH host in `session` (parallel).

The worker stops, and names `help setup`, when it has no reachable
registry, when `Pkg.is_manifest_current` is not `true` (a Manifest with
no `project_hash` counts), or when Manifest `julia_version` is missing
or its minor differs from that Julia. Otherwise the worker runs
`Pkg.instantiate(; manifest=true, update_registry=false, julia_version_strict=true)`.

`julia` is the remote Julia path (`"auto"` detects per host, same as
`setup instantiate` / `drive --julia`). Returns [`SyncResult`](@ref).

Typical first-time remote prep:

```julia
session = KitSession(workers=["child:user@h1"], remote="/path/to/project", yes=true)
setup!(session, :ship_tree, :instantiate)  # or sync!(…; mode=:ship_tree) then instantiate!
```

Also available as [`setup!`](@ref)`(session, :instantiate; julia=…)`.
"""
function instantiate!(
        session::KitSession;
        julia::AbstractString = "auto",
        run_id::Union{Nothing, AbstractString} = nothing,
    )::SyncResult
    isempty(session.hosts) && throw(
        ArgumentError(
            explain_no_hosts(; surface = hint_surface(session), kind = :ssh),
        )
    )
    validate_setup_hosts(session.hosts)
    snap = run_id === nothing ? nothing : validate_run_id(run_id)
    return _with_kit_inproc_run!(:instantiate) do
        apply_session_env!(session)
        preflight_setup_ssh(session.hosts) || return SyncResult(
            false,
            HostResult[];
            ok = false,
        )
        remote_path = _project_work_root(
            session.hosts, session.project;
            cli_override = session.remote, run_id = snap,
        )
        julia_path = isempty(strip(String(julia))) ? "auto" : String(julia)
        raw = instantiate_remotes(
            session.hosts,
            julia_path,
            remote_path,
            session.project;
            path_anchor = session.project,
        )
        hrs = hasproperty(raw, :hosts) ? collect(HostResult, raw.hosts) : HostResult[]
        return SyncResult(
            raw.cancelled,
            hrs;
            ok = !raw.cancelled && raw.failed == 0,
        )
    end
end

"""After `sync!(; mode=:ship_tree)`, instantiate on hosts that still lack deps.

Returns `nothing` when every host already resolves, else [`instantiate!`](@ref).
Pass `run_id=` to force the ID from that ship when the local record is not enough.
"""
function instantiate_after_ship!(
        session::KitSession;
        julia::AbstractString = "auto",
        run_id::Union{Nothing, AbstractString} = nothing,
    )::Union{Nothing, SyncResult}
    isempty(session.hosts) && return nothing
    snap = run_id === nothing ? nothing : validate_run_id(run_id)
    return _with_kit_inproc_run!(:instantiate) do
        apply_session_env!(session)
        rr = _project_work_root(
            session.hosts, session.project;
            cli_override = session.remote, run_id = snap,
        )
        any(h -> probe_remote_project_deps(h, rr) !== nothing, session.hosts) ||
            return nothing
        return instantiate!(session; julia = julia, run_id = snap)
    end
end
