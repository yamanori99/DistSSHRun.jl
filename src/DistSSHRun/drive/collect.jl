# collect! — pull result trees from remotes (same core as `drive --collect-*`).

"""
    collect!(
        session::KitSession,
        local_root::AbstractString;
        merge=false,
        hosts=nothing,
    )

Rsync result files from SSH hosts into `local_root`. Pull-back rsync
uses `--safe-links` so a remote symlink that points outside the copied
tree is skipped. Tar pull-back is deferred (remote mtimes on outputs).

Collect modes:
- `merge=false` → **collect-missing** (CLI `drive --collect-missing`)
- `merge=true` → **collect-overwrite** (CLI `drive --collect-overwrite`)

Distinct from drive's automatic **post-run-new** (sentinel / newer-than-run) and go's
**slot-overwrite**. Returns [`CollectResult`](@ref).

A root that is the session project or a parent of it is refused (`ok=false`,
exit code 1). Point it at a result directory inside the project.
"""
function collect!(
        session::KitSession,
        local_root::AbstractString;
        merge::Bool = false,
        hosts::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
    )::CollectResult
    host_list = hosts === nothing ? session.hosts : collect(String, hosts)
    isempty(host_list) && throw(
        ArgumentError(
            explain_no_hosts(; surface = hint_surface(session), kind = :collect),
        )
    )
    return _with_kit_inproc_run!(:collect) do
        apply_session_env!(session)
        ok = drive_collect_tree(
            String(local_root),
            host_list;
            merge = merge,
            project_root = session.project,
            path_anchor = canonical_local_path(session.project),
        )
        return CollectResult(ok, ok ? 0 : 1)
    end
end
