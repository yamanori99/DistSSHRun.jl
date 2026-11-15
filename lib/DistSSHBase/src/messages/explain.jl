# Cross-cutting user-facing errors: diagnose (facts) then explain (words).
#
# This file owns shared `surface=:cli|:api` helpers and message builders used by
# more than one entry point (drive / go / setup / hostinfo / pipeline! / …).
# Domain-specific diagnose/explain pairs stay next to their domain
# (`demos.jl` for demo-install tips, etc.).
#
# See CONTRIBUTING.md ("Errors: diagnose then explain").

"""Normalize explain surface (`:cli` or `:api`)."""
function _normalize_hint_surface(surface::Symbol)::Symbol
    surface === :cli || surface === :api ||
        throw(ArgumentError("hint surface must be :cli or :api, got $(repr(surface))"))
    return surface
end

"""Join a headline with an optional hint line (`nothing` → headline only)."""
join_explained_message(headline::AbstractString, ::Nothing)::String = string(headline)
join_explained_message(headline::AbstractString, hint::AbstractString)::String =
    string(headline, '\n', hint)

"""Missing `DRIVER=` / `driver=` for `pipeline_config_from_env`."""
function explain_pipeline_driver_missing(; surface::Symbol = :api)::String
    surface = _normalize_hint_surface(surface)
    if surface === :cli
        return "set DRIVER=path/to/driver.jl (or pass a driver path to the pipeline entry)"
    end
    return "set DRIVER=path/to/driver.jl or pass driver= keyword"
end

# --- hosts file / SSH hosts --------------------------------------------------

function explain_hosts_file_not_found(
        path::AbstractString;
        surface::Symbol = :cli,
    )::String
    surface = _normalize_hint_surface(surface)
    p = String(path)
    head = "hosts file not found: $p"
    hint = if surface === :api
        "Hint: pass hosts_file=\"…\" to DistSSHSession / go!, or set ENV[\"DISTSSH_HOSTS_FILE\"]"
    else
        "Hint: pass --hosts-file PATH, or set DISTSSH_HOSTS_FILE"
    end
    return join_explained_message(head, hint)
end

function explain_hosts_file_empty(
        path::AbstractString;
        surface::Symbol = :cli,
    )::String
    surface = _normalize_hint_surface(surface)
    p = String(path)
    head = "hosts file has no hosts: $p"
    hint = if surface === :api
        "Hint: add host lines (or host:N), or pass workers=[…] instead"
    else
        "Hint: add host lines (or host:N), or pass hosts on the command line"
    end
    return join_explained_message(head, hint)
end

"""
No SSH / inventory hosts on a session.

`kind` is `:ssh` (sync/setup/instantiate), `:collect`, `:hostinfo`, or `:pool`.
"""
function explain_no_hosts(;
        surface::Symbol = :api,
        kind::Symbol = :ssh,
    )::String
    surface = _normalize_hint_surface(surface)
    kind in (:ssh, :collect, :hostinfo, :pool) ||
        throw(ArgumentError("explain_no_hosts kind must be :ssh, :collect, :hostinfo, or :pool"))
    if kind === :pool
        head = "DistSSHSession has no hosts for pool!"
        hint = if surface === :api
            "Hint: pass workers=[\"parent:2\", …] or workers=[\"user@host\", …]"
        else
            "Hint: pass local and/or SSH hosts (see help pool)"
        end
        return join_explained_message(head, hint)
    elseif kind === :hostinfo
        head = "DistSSHSession has no hosts for hostinfo"
        hint = if surface === :api
            "Hint: pass workers=[\"parent\", …] or workers=[\"user@host\", …]"
        else
            "Hint: pass local and/or SSH hosts (see help hostinfo)"
        end
        return join_explained_message(head, hint)
    elseif kind === :collect
        head = "collect! needs hosts in session or hosts= keyword"
        hint = if surface === :api
            "Hint: DistSSHSession(workers=[\"user@host\", …]) or collect!(…; hosts=[…])"
        else
            "Hint: pass HOST after --collect-missing / --collect-overwrite ROOT"
        end
        return join_explained_message(head, hint)
    end
    head = "DistSSHSession has no SSH hosts"
    hint = if surface === :api
        "Hint: pass workers= with machine tokens, or hosts_file= / machine_file="
    else
        "Hint: pass machine tokens (`N*host`), or one of --hosts, --hosts-file, --machine-file"
    end
    return join_explained_message(head, hint)
end

"""go / drive / ride listed a host without `:N`."""
function explain_bare_placement_tokens(
        tokens::AbstractVector{<:AbstractString};
        surface::Symbol = :cli,
    )::String
    surface = _normalize_hint_surface(surface)
    bare = String[]
    for raw in tokens
        s = String(raw)
        try
            p = parse_placement_token(s)
            p.n === nothing && push!(bare, s)
        catch e
            e isa ArgumentError && push!(bare, s)
            e isa ArgumentError || rethrow()
        end
    end
    isempty(bare) && return ""
    listed = join(bare, ' ')
    head = "each go / drive / ride token needs an explicit worker count; bare $(listed) is not allowed"
    hint = if surface === :api
        "Hint: write `N*host` or use --local-workers for local slots. go --repeat still treats a bare host as one slot."
    else
        "Hint: write `2*host` (quote `--hosts` so the shell does not glob `*`). Use --local-workers for local slots."
    end
    return join_explained_message(head, hint)
end

# --- local host tools (ssh / git) --------------------------------------------

const _HOST_TOOL_NAMES = ("ssh", "git")

function _normalize_host_tool(name::AbstractString)::String
    n = String(name)
    n == "ssh" || n == "scp" || n == "git" ||
        throw(ArgumentError("host tool must be ssh, scp, or git, got $(repr(n))"))
    return n
end

"""Hint line when `ssh` / `git` is absent from `PATH`."""
function explain_host_tool_hint(tool::AbstractString; surface::Symbol = :api)::String
    _normalize_hint_surface(surface)
    t = _normalize_host_tool(tool)
    pkg = cli_entry()
    t == "ssh" && return "Hint: $pkg does not install OpenSSH; see Requirements"
    t == "scp" && return "Hint: $pkg does not install OpenSSH (scp); see Requirements"
    return "Hint: $pkg does not install git; needed for clone / sync / pull (see Requirements)"
end

"""Full message when a required host tool is not on `PATH`."""
function explain_host_tool_missing(tool::AbstractString; surface::Symbol = :api)::String
    t = _normalize_host_tool(tool)
    return join_explained_message("$t not found in PATH", explain_host_tool_hint(t; surface = surface))
end

# --- setup / clone -----------------------------------------------------------

function explain_clone_repo_required(; surface::Symbol = :api)::String
    surface = _normalize_hint_surface(surface)
    if surface === :api
        return "setup!(session, :git_clone) requires repo=\"git-url\" " *
            "(no silent origin lookup; clone runs on the remote)"
    end
    return "setup git-clone requires --repo URL " *
        "(no silent origin lookup; clone runs on the remote)"
end

function explain_clone_origin_missing(; surface::Symbol = :cli)::String
    surface = _normalize_hint_surface(surface)
    if surface === :api
        return "Could not read git remote `origin`; pass repo=\"git-url\" to setup!(…, :git_clone)"
    end
    return "Could not read git remote `origin`; pass --repo URL"
end
