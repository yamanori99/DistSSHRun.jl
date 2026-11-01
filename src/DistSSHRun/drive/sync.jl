# sync! — rsync or git sync via shared DistSSHRun cores (not CLI argv).

"""
    sync!(session::KitSession; mode=:sync)

Sync local project to SSH hosts (call explicitly; go/drive do not call this by default).

- `mode=:sync` — push the local branch to origin, then check out that commit on each remote as a detached HEAD (confirm unless `session.yes`). Does not run `git pull`. A dirty tree is refused.
- `mode=:ship_tree` — pack the git file list into a tar and extract under
  `runs/<run_id>/src/` (confirm unless `session.yes`).

Also available as `setup!(session, :ship_tree)` / `setup!(session, :sync)`.

Returns [`SyncResult`](@ref).
"""
function sync!(
        session::KitSession;
        mode = :sync,
        gitignore::Bool = true,
        allow_external_symlinks::Bool = false,
        await_inputs::Bool = true,
    )::SyncResult
    # Untyped kw: JETLS treats omitted kwargs as `nothing`, not `Union{Symbol,Bool}`.
    mode === false && throw(ArgumentError("sync!: mode=false means skip sync; do not call sync!"))
    kind = mode
    kind === :rsync && _throw_rsync_removed()
    kind === :ship_tree || kind === :sync || throw(
        ArgumentError(
            "sync! mode must be :ship_tree or :sync, got $(repr(kind))",
        )
    )
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
            raw = ship_project_to_hosts!(
                session.hosts,
                session.project,
                remote_path;
                confirm = !session.yes,
                path_anchor = session.project,
                allow_external_symlinks = allow_external_symlinks,
                await_inputs = await_inputs,
            )
            if raw.cancelled
                return SyncResult(true, HostResult[]; ok = false)
            end
            failed = count(hr -> !hr.ok, raw.host_results)
            return SyncResult(false, raw.host_results; ok = failed == 0)
        else
            remote_path = session_remote_root(session)
            raw = git_sync_project_to_hosts!(
                session.hosts,
                session.project,
                remote_path;
                do_push = true,
                do_pull = true,
                confirm = !session.yes,
            )
            if raw.cancelled
                return SyncResult(true, HostResult[]; ok = false)
            end
            return SyncResult(false, raw.host_results; ok = raw.ok)
        end
    end
end
