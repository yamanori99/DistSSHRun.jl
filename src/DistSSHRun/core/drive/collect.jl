# collect! — pull result trees from remotes (same core as `drive --collect-*`).

"""
    collect!(
        session::DistSSHSession,
        local_root::AbstractString;
        merge=false,
        best_effort=false,
        hosts=nothing,
        julia=nothing,
        remote_root=nothing,
    )

Pull result files from SSH hosts into `local_root` with stdlib Tar.
Remote mtimes are not kept. A non-executable file arrives as mode `0644`,
and an executable file as `0755`. A symlink that points outside the copied
tree is refused. `julia` is the remote executable (`nothing` auto-detects).

Collect modes:
- `merge=false` → **collect-missing** (CLI `drive --collect-missing`)
- `merge=true` → **collect-overwrite** (CLI `drive --collect-overwrite`)

Distinct from drive's automatic **post-run-new** (sentinel / newer-than-run) and go's
**slot-overwrite**. Returns [`CollectResult`](@ref) (`skipped` lists hosts that were not
collected). By default any skipped host fails the run; pass `best_effort=true` or
`drive --best-effort` on collect-only CLI to continue (skipped hosts are still listed).

A root that is the session project or a parent of it is refused (`ok=false`,
exit code 1). Point it at a result directory inside the project.
`run_id=` selects `runs/<ID>/src`. When omitted, a present controller
`DISTSSH_RUN_DIR/run.toml` with `provenance.selection` recovers that
execution's source instead of a later last-snapshot record.
"""
function collect!(
        session::DistSSHSession,
        local_root::AbstractString;
        merge::Bool = false,
        best_effort::Bool = false,
        hosts::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
        julia::Union{Nothing, AbstractString} = nothing,
        run_id::Union{Nothing, AbstractString} = nothing,
        remote_root::Union{Nothing, AbstractString} = nothing,
    )::CollectResult
    host_list = hosts === nothing ? session.hosts : collect(String, hosts)
    isempty(host_list) && throw(
        ArgumentError(
            explain_no_hosts(; surface = hint_surface(session), kind = :collect),
        )
    )
    opts = collect_job_options(;
        merge = merge,
        best_effort = best_effort,
        remote_root = remote_root !== nothing ? remote_root : session.remote,
        run_id = run_id,
        julia = julia,
    )
    snap = opts.run_id
    session = if opts.remote_root !== session.remote
        DistSSHSession(
            project = session.project,
            workers = session.tokens,
            remote = opts.remote_root,
            quiet = session.quiet,
            verbosity = session.verbosity,
            yes = session.yes,
        )
    else
        session
    end
    return _with_kit_inproc_run!(:collect) do
        apply_session_env!(session)
        return _with_session_remote_env!(session) do
            ok, skipped = drive_collect_tree(
                String(local_root),
                host_list;
                merge = opts.merge,
                best_effort = opts.best_effort,
                project_root = session.project,
                path_anchor = canonical_local_path(session.project),
                julia = opts.julia,
                run_id = snap,
            )
            return CollectResult(ok, ok ? 0 : 1, skipped)
        end
    end
end
