# DistSSHSession — shared context for drive / sync / collect APIs.

"""Runtime context for `sync!`, `drive!`, `collect!`."""
mutable struct DistSSHSession
    project::String
    hosts::Vector{String}
    tokens::Vector{String}
    remote::Union{Nothing, String}
    quiet::Bool
    verbosity::Symbol
    yes::Bool
    include_parent_for_size::Bool
    cli_session::CliSharedFlags
end

"""
    DistSSHSession(; project=pwd(), workers=[], remote=nothing, hosts_file=nothing,
               quiet=false, verbosity=nothing, yes=true, include_parent_for_size=false)

Build a session for drive APIs. `workers` is a CLI-style host list.
`setup!` / `pool!` / `sync!` / `collect!` accept a bare list
(`child:user@host`). `go!` / `drive!` / `ride!` / `pipeline!` require `:N`
on listed tokens (`parent:2`, `child:user@host:1`).

`session.hosts` keeps remote SSH names only (for sync / collect).
`session.tokens` keeps the original tokens (including `parent:N`).
`remote` is the remote project path (`DISTRIBUTED_REMOTE_PROJECT_ROOT`).
A value that starts with `~` stays a remote-shell layout (not `expanduser`
on the kit parent).

`hosts_file` is appended when given. `ENV["DISTSSH_HOSTS_FILE"]` is used
only when `hosts_file` is omitted **and** `workers` is empty (same as
[`go!`](@ref)). Non-empty `workers` do not re-read that ENV.
`verbosity` is `:verbose` | `:progress` | `:quiet` (`quiet=true` implies `:quiet`).
API default `yes=true` skips confirm prompts.
"""
function DistSSHSession(;
        project::AbstractString = pwd(),
        workers::AbstractVector{<:AbstractString} = String[],
        remote::Union{Nothing, AbstractString} = nothing,
        hosts_file::Union{Nothing, AbstractString} = nothing,
        quiet::Bool = false,
        verbosity::Union{Nothing, Symbol} = nothing,
        yes::Bool = true,
        include_parent_for_size::Bool = false,
    )
    tokens = String[String(h) for h in workers]
    hf = if hosts_file !== nothing
        String(strip(hosts_file))
    elseif isempty(tokens)
        strip(get(ENV, "DISTSSH_HOSTS_FILE", ""))
    else
        ""
    end
    hf_path = isempty(hf) ? nothing : hf
    cli = CliSharedFlags(
        quiet = quiet,
        verbosity = verbosity,
        yes = yes,
        hosts_file = hf_path,
        hint_surface = :api,
    )
    tokens = String[String(h) for h in workers]
    if hf_path !== nothing
        for line in read_hosts_file_lines(hf_path; surface = :api)
            push!(tokens, line)
        end
    end
    parsed = parse_worker_tokens(tokens)
    include_parent = include_parent_for_size || parsed.parent_autosize
    proj = canonical_local_path(project)
    rr = remote === nothing ? nothing : String(strip(String(remote)))
    rr !== nothing && isempty(rr) && (rr = nothing)
    return DistSSHSession(
        proj,
        copy(parsed.child_hosts),
        parsed.tokens,
        rr,
        cli.quiet,
        cli.verbosity,
        yes,
        include_parent,
        cli,
    )
end

"""Apply session fields to `ENV` and kit CLI session flags.

Sets `DISTRIBUTED_PROJECT_ROOT` from `session.project`. Does **not** write
`DISTRIBUTED_REMOTE_PROJECT_ROOT`: `session.remote` is passed as
`cli_override` into location helpers. Callers that must expose a remote
layout to `remote_layout_path` / workers (drive / ride) set that ENV only
inside a frame that restores the caller's value. Overlapping in-process kit
runs are refused (`_acquire_kit_inproc_run!`); nested same-task runs share
one owner task.
"""
function apply_session_env!(session::DistSSHSession)
    ENV["DISTRIBUTED_PROJECT_ROOT"] = session.project
    session.cli_session.quiet = session.quiet
    session.cli_session.yes = session.yes
    # Non-explicit sessions auto-resolve to `:verbose` when stdout is a pipe
    # (Pkg.test). Do not wipe an ambient `:progress` / `:quiet` pin — that
    # flipped `writeln_field("Log file", …)` back on under `setup!` (#238).
    if !(session.cli_session.verbosity_explicit || session.quiet)
        ambient = kit_verbosity()
        if ambient in (:progress, :quiet) && session.verbosity === :verbose
            session.verbosity = ambient
            session.quiet = ambient === :quiet
            session.cli_session.quiet = session.quiet
        end
    end
    session.cli_session.verbosity = session.verbosity
    apply_shared_cli_flags!(session.cli_session)
    return session
end

"""Run `f` with `session.remote` in `DISTRIBUTED_REMOTE_PROJECT_ROOT`, then restore.

Needed for `remote_layout_path` / collect mapping when `apply_session_env!`
does not persist the remote. `session.remote === nothing` leaves the ENV alone.
"""
function _with_session_remote_env!(f, session::DistSSHSession)
    prev = get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", nothing)
    try
        rr = session.remote
        if rr isa AbstractString
            ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = remote_env_project_root(rr)
        end
        return f()
    finally
        if prev === nothing
            delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
        else
            ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = prev
        end
    end
end

"""Resolved remote repository root for this session."""
function session_remote_root(session::DistSSHSession)::String
    return resolve_remote_project_root(session.project; cli_override = session.remote)
end

"""Explain surface for this session (`:cli` or `:api`)."""
hint_surface(session::DistSSHSession)::Symbol = session.cli_session.hint_surface
