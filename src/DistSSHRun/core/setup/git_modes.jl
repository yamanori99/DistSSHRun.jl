# Git-based setup / pre-run sync names (CLI git-* / API :git_*).

const _SETUP_GIT_SUBCOMMAND_CLI = (
    :git_clone => "git-clone",
    :git_sync => "git-sync",
    :git_pull => "git-pull",
)

const _SETUP_GIT_SUBCOMMAND_LEGACY_CLI = Dict(
    "clone" => "git-clone",
    "sync" => "git-sync",
    "pull" => "git-pull",
)

"""Reject old setup subcommand tokens (`clone` / `sync` / `pull`)."""
function _throw_setup_removed_git_subcommand!(name::AbstractString)
    repl = get(_SETUP_GIT_SUBCOMMAND_LEGACY_CLI, String(name), nothing)
    repl === nothing && return
    throw(
        ArgumentError(
            join_explained_message(
                "setup $(name) was removed; use `$(cli_m()) setup $(repl)`.",
                "Run `$(cli_m()) help setup` for flags.",
            ),
        ),
    )
end

"""Reject old `setup!` git mode symbols (`:clone`, `:sync`, `:pull`)."""
function _reject_removed_git_setup_mode!(mode::Symbol)
    if mode === :clone
        throw(
            ArgumentError(
                join_explained_message(
                    "setup! :clone was removed; use :git_clone",
                    "CLI: `$(cli_m()) setup git-clone`.",
                ),
            ),
        )
    elseif mode === :sync
        throw(
            ArgumentError(
                join_explained_message(
                    "setup! :sync was removed; use :git_sync",
                    "CLI: `$(cli_m()) setup git-sync`.",
                ),
            ),
        )
    elseif mode === :pull
        throw(
            ArgumentError(
                join_explained_message(
                    "setup! :pull was removed; use :git_pull",
                    "CLI: `$(cli_m()) setup git-pull`.",
                ),
            ),
        )
    end
    return nothing
end

"""Reject old pre-run git sync (`:sync` on `sync=` / `sync_mode`)."""
function _reject_removed_pre_run_git_sync!(sym::Symbol; api::AbstractString)
    sym === :sync || throw(ArgumentError("internal: expected :sync"))
    throw(
        ArgumentError(
            join_explained_message(
                "$api: sync=:sync was removed; use sync=:git_sync",
                "CLI: --git-sync.",
            ),
        ),
    )
end

function _throw_drive_go_removed_git_sync_flag!(command::AbstractString)
    throw(
        ArgumentError(
            join_explained_message(
                "$(command) --sync was removed; use --git-sync",
                "Run `$(cli_m()) help $(command)` for flags.",
            ),
        ),
    )
end

function _throw_go_removed_skip_sync_flag!()
    throw(
        ArgumentError(
            join_explained_message(
                "go --skip-sync was removed; use --skip-git-sync",
                "`--skip-git-guard` still skips pre-run git sync.",
            ),
        ),
    )
end

"""Reject old `sync!(; mode=:sync)`."""
function _reject_removed_sync_mode!(mode::Symbol)
    mode === :sync &&
        throw(
        ArgumentError(
            join_explained_message(
                "sync! mode=:sync was removed; use mode=:git_sync",
                "Or `setup!(session, :git_sync)`.",
            ),
        ),
    )
    return nothing
end

function _throw_drive_removed_sync_script_flag!()
    throw(
        ArgumentError(
            join_explained_message(
                "drive --sync-script was removed; use --worker-include",
                "Run `$(cli_m()) help drive` for flags.",
            ),
        ),
    )
end

"""Reject `drive!` `sync_script=` (renamed to `worker_include=`)."""
function _reject_removed_drive_worker_include_kw!(sync_script::Union{Nothing, Bool})
    sync_script === nothing && return
    throw(
        ArgumentError(
            join_explained_message(
                "drive! sync_script= was removed; use worker_include=",
                "CLI: --worker-include.",
            ),
        ),
    )
end
