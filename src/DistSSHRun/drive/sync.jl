# sync! — git sync via shared DistSSHRun cores (not CLI argv).

"""
    sync!(session::KitSession; mode=:git_sync)

Sync local project to SSH hosts (call explicitly; go/drive do not call this by default).

- `mode=:git_sync` — push the local branch to origin, then check out that commit on each remote as a detached HEAD (confirm unless `session.yes`). Does not run `git pull`. Requires an existing clone at `session.remote`; on a new target run `setup!(session, :git_clone; repo=...)` first. A dirty tree is refused unless `allow_dirty=true` (CLI `setup git-sync --skip-git-guard`; deploy record `dirty=true`).
- `mode=:ship_tree` — pack the project (each directory's `.gitignore`) into a tar and extract under
  `runs/<run_id>/src/` (confirm unless `session.yes`).

Also available as `setup!(session, :ship_tree)` / `setup!(session, :git_sync)`.

Returns [`SyncResult`](@ref). For `:ship_tree`, [`result_content_tree_hash`](@ref)
and [`result_remote_run_id`](@ref) read that ship. Other modes return `nothing`.
"""
function sync!(
        session::KitSession;
        mode = :git_sync,
        gitignore::Bool = true,
        allow_external_symlinks::Bool = false,
        await_inputs::Bool = true,
        extra_files::Vector{String} = String[],
        allow_dirty::Bool = false,
    )::SyncResult
    # Untyped kw: JETLS treats omitted kwargs as `nothing`, not `Union{Symbol,Bool}`.
    mode === false && throw(ArgumentError("sync!: mode=false means skip sync; do not call sync!"))
    kind = mode
    kind isa Symbol && _reject_removed_sync_mode!(kind)
    kind === :rsync && _throw_rsync_removed()
    kind === :ship_tree || kind === :git_sync || throw(
        ArgumentError(
            "sync! mode must be :ship_tree or :git_sync, got $(repr(kind))",
        )
    )
    check_setup_options!(kind; extra_files = extra_files, allow_dirty = allow_dirty)
    gitignore || throw(ArgumentError("sync! gitignore is not valid for mode=:$kind"))
    isempty(session.hosts) && throw(
        ArgumentError(
            explain_no_hosts(; surface = hint_surface(session), kind = :ssh),
        )
    )
    return _with_kit_inproc_run!(:sync) do
        apply_session_env!(session)
        warn_project_sshflags(session.project)
        if kind === :ship_tree
            remote_path = remote_deploy_root(
                session.project; cli_override = session.remote,
            )
            raw = ship_tree!(
                session.project,
                session.hosts,
                remote_path;
                confirm = !session.yes,
                path_anchor = session.project,
                allow_external_symlinks = allow_external_symlinks,
                await_inputs = await_inputs,
                extra_files = extra_files,
            )
            return _sync_result_from_ship(raw)
        else
            remote_path = session_remote_root(session)
            deploy = remote_deploy_root(
                session.project; cli_override = session.remote,
            )
            raw = git_sync_project_to_hosts!(
                session.hosts,
                session.project,
                remote_path;
                do_push = true,
                do_pull = true,
                confirm = !session.yes,
                allow_dirty = allow_dirty,
            )
            if raw.cancelled
                return SyncResult(true, HostResult[]; ok = false)
            end
            result = SyncResult(false, raw.host_results; ok = raw.ok)
            if result.ok
                forget_last_snapshot_default!(session.project, deploy)
                ok_hosts = String[String(hr.host) for hr in result.hosts if hr.ok]
                commit_deploy_record_after_git!(
                    ok_hosts, deploy, session.project, :git_sync;
                    dirty = allow_dirty,
                )
            end
            return result
        end
    end
end

function _sync_result_from_ship(raw::ShipTreeResult)::SyncResult
    if raw.cancelled
        return SyncResult(
            true, HostResult[];
            ok = false,
            content_tree_hash = raw.content_tree_hash,
            run_id = raw.run_id,
        )
    end
    failed = count(hr -> !hr.ok, raw.host_results)
    return SyncResult(
        false, raw.host_results;
        ok = failed == 0,
        content_tree_hash = raw.content_tree_hash,
        run_id = raw.run_id,
    )
end
