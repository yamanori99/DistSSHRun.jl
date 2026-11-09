# Run commands no longer transfer code (#386). Reject removed CLI flags and API kwargs.

function _run_transfer_m()::String
    return _kit_user_cli_m()
end

function _hint_setup_git_sync()::String
    return "Run `$(_run_transfer_m()) setup git-sync HOST` first, then run without transfer flags."
end

function _hint_setup_ship_tree(command::AbstractString)::String
    m = _run_transfer_m()
    return string(
        "Run `$m setup ship-tree HOST`, then `$m setup instantiate HOST`, ",
        "then `$m $command --snapshot ID`.",
    )
end

function _hint_setup_skip_git_guard()::String
    return "Use `$(_run_transfer_m()) setup git-sync --skip-git-guard HOST` when the worktree may be dirty."
end

"""Reject a removed transfer flag on `go` / `drive` CLI."""
function _reject_run_transfer_cli!(command::AbstractString, flag::AbstractString)
    m = _run_transfer_m()
    if flag in ("--git-sync", "--sync")
        throw(
            ArgumentError(
                join_explained_message(
                    "$(command): $(flag) was removed; $m no longer transfers code on run.",
                    _hint_setup_git_sync(),
                ),
            ),
        )
    elseif flag == "--ship-tree"
        throw(
            ArgumentError(
                join_explained_message(
                    "$(command): --ship-tree was removed; $m no longer transfers code on run.",
                    _hint_setup_ship_tree(command),
                ),
            ),
        )
    elseif flag in ("--skip-git-sync", "--skip-sync")
        throw(
            ArgumentError(
                join_explained_message(
                    "$(command): $(flag) was removed.",
                    "Default is already no pre-run sync; use setup to deploy.",
                ),
            ),
        )
    elseif flag == "--skip-git-guard"
        throw(
            ArgumentError(
                join_explained_message(
                    "$(command): --skip-git-guard was removed from run.",
                    _hint_setup_skip_git_guard(),
                ),
            ),
        )
    elseif flag == "--allow-external-symlinks"
        throw(
            ArgumentError(
                join_explained_message(
                    "$(command): --allow-external-symlinks was removed; pass it to `$(m) setup ship-tree`.",
                    "Run `$(m) help setup`.",
                ),
            ),
        )
    else
        throw(
            ArgumentError(
                join_explained_message(
                    "$(command): $(flag) was removed; $m no longer transfers code on run.",
                    "Run `$(m) help setup`.",
                ),
            ),
        )
    end
end

"""Reject `sync=` / `sync_mode` on run APIs (`go!`, `drive!`, `pipeline!`, `execute!`)."""
function _reject_run_transfer_kw!(
        api::AbstractString,
        sync::Union{Symbol, Bool, Nothing};
        surface::Symbol = :api,
    )
    surface = _normalize_hint_surface(surface)
    if sync === nothing || sync === false
        return nothing
    end
    sym = sync isa Symbol ? sync : nothing
    m = _run_transfer_m()
    if sym === :rsync
        _throw_rsync_removed()
    elseif sym === :sync
        throw(
            ArgumentError(
                join_explained_message(
                    "$api: sync=:sync was removed; $m no longer transfers on run.",
                    "Use `setup!(session, :git_sync)` or CLI `setup git-sync`.",
                ),
            ),
        )
    elseif sym === :git_sync
        throw(
            ArgumentError(
                join_explained_message(
                    "$api: sync=:git_sync was removed; $m no longer transfers on run.",
                    _hint_setup_git_sync(),
                ),
            ),
        )
    elseif sym === :ship_tree
        cmd = startswith(api, "drive") ? "drive" : "go"
        throw(
            ArgumentError(
                join_explained_message(
                    "$api: sync=:ship_tree was removed; $m no longer transfers on run.",
                    _hint_setup_ship_tree(cmd),
                ),
            ),
        )
    else
        throw(
            ArgumentError(
                join_explained_message(
                    "$api: sync=$(repr(sync)) was removed; $m no longer transfers on run.",
                    "Run `$(m) help setup`.",
                ),
            ),
        )
    end
end

function _reject_pipeline_sync_env!(raw::AbstractString)
    s = lowercase(strip(String(raw)))
    isempty(s) && return nothing
    s in ("off", "false", "0", "skip", "no") && return nothing
    m = _run_transfer_m()
    throw(
        ArgumentError(
            join_explained_message(
                "SYNC_MODE=$(repr(raw)) was removed; pipeline! no longer syncs.",
                string(
                    "Deploy with `$(m) setup git-sync` or `$(m) setup ship-tree`, ",
                    "then set SYNC_MODE=off or omit it.",
                ),
            ),
        ),
    )
end

function _reject_pipeline_sync_kw!(sync::Union{Symbol, Bool, Nothing})
    return _reject_run_transfer_kw!("pipeline!", sync; surface = :api)
end

"""Script outside `project` cannot run without setup ship-tree (and optional extra file)."""
function _reject_script_outside_project_run!(
        command::AbstractString,
        project::AbstractString,
        script_path::AbstractString;
        snapshot::Union{Nothing, AbstractString} = nothing,
        remote_argv::Bool = false,
    )
    remote_argv && return nothing
    _script_inside_project(project, script_path) && return nothing
    snapshot !== nothing && return nothing
    m = _run_transfer_m()
    throw(
        ArgumentError(
            join_explained_message(
                "$(command): script must be inside project ($(canonical_local_path(project))): $(canonical_local_path(script_path))",
                string(
                    "Ship it with `$(m) setup ship-tree HOST` (extra files supported), ",
                    "then run with `--snapshot ID`.",
                ),
            ),
        ),
    )
end
