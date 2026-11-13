# collect! — pull result trees from remotes (same core as `drive --collect-*`).

"""
    collect!(
        session::KitSession,
        local_root::AbstractString;
        merge=false,
        hosts=nothing,
        julia=nothing,
    )

Pull result files from SSH hosts into `local_root` with stdlib Tar.
Remote mtimes are not kept. A non-executable file arrives as mode `0644`,
and an executable file as `0755`. A symlink that points outside the copied
tree is refused. `julia` is the remote executable (`nothing` auto-detects).

Collect modes:
- `merge=false` → **collect-missing** (CLI `drive --collect-missing`)
- `merge=true` → **collect-overwrite** (CLI `drive --collect-overwrite`)

Distinct from drive's automatic **post-run-new** (sentinel / newer-than-run) and go's
**slot-overwrite**. Returns [`CollectResult`](@ref).

A root that is the session project or a parent of it is refused (`ok=false`,
exit code 1). Point it at a result directory inside the project.
`run_id=` selects `runs/<ID>/src`. When omitted, a present controller
`DISTSSH_RUN_DIR/run.toml` with `provenance.selection` recovers that
execution's source instead of a later last-snapshot record.
"""
function collect!(
        session::KitSession,
        local_root::AbstractString;
        merge::Bool = false,
        hosts::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
        julia::Union{Nothing, AbstractString} = nothing,
        run_id::Union{Nothing, AbstractString} = nothing,
    )::CollectResult
    host_list = hosts === nothing ? session.hosts : collect(String, hosts)
    isempty(host_list) && throw(
        ArgumentError(
            explain_no_hosts(; surface = hint_surface(session), kind = :collect),
        )
    )
    snap = run_id === nothing ? nothing : validate_run_id(run_id)
    return _with_kit_inproc_run!(:collect) do
        apply_session_env!(session)
        return _with_session_remote_env!(session) do
            ok = drive_collect_tree(
                String(local_root),
                host_list;
                merge = merge,
                project_root = session.project,
                path_anchor = canonical_local_path(session.project),
                julia = julia,
                run_id = snap,
            )
            return CollectResult(ok, ok ? 0 : 1)
        end
    end
end
