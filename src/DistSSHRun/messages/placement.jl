# Head-machine placement labels (drive workers, go head slots).

"""Hostname of the machine running this DistSSHRun process (process 1)."""
function kit_head_host_label()::String
    return string(gethostname())
end

"""Role phrase after the hostname in `head:` placement lines."""
function kit_head_placement_role()::String
    return cli_entry() === :DistSSHQueue ? "queue host" : "this machine"
end

"""User-facing head placement line, e.g. `head: host (this machine), 2 workers`."""
function format_kit_head_placement(n::Integer, unit::AbstractString)::String
    h = kit_head_host_label()
    role = kit_head_placement_role()
    return "head: $h ($role), $n $(unit)"
end

"""Remote host placement summary, e.g. `node1 (8 workers)`."""
function format_kit_remote_placement(host::AbstractString, n::Integer, unit::AbstractString)::String
    return "$(String(host)) ($n $(unit))"
end

"""`go` with no hosts and no `--head-slots`: one implicit head slot."""
function format_kit_go_implicit_head_slot()::String
    h = kit_head_host_label()
    role = kit_head_placement_role()
    return "head: $h ($role), 1 slot (no hosts given)"
end

"""
Resolve `go` head slot count.

Empty `host_tokens` and unset `head_slots` → one implicit head slot.
Empty hosts with explicit `head_slots=0` → zero (caller should error).
"""
function resolve_go_head_slots(
        host_tokens::AbstractVector{<:AbstractString},
        head_slots::Union{Nothing, Integer},
    )::Tuple{Int, Bool}
    if !isempty(host_tokens)
        n = head_slots === nothing ? 0 : Int(head_slots)
        n < 0 && throw(ArgumentError("--head-slots must be >= 0, got $n"))
        return n, false
    end
    if head_slots !== nothing
        n = Int(head_slots)
        n < 0 && throw(ArgumentError("--head-slots must be >= 0, got $n"))
        return n, false
    end
    return 1, true
end

"""Usage error when a job has no workers (drive) or slots (go)."""
function zero_placement_usage_error(command::Symbol; surface::Symbol = :cli)::String
    surface = _normalize_hint_surface(surface)
    cmd = String(command)
    if command === :go
        head = "go: no execution slots"
        hint = if surface === :api
            "Hint: pass --head-slots N and/or machine tokens (`N*host`)."
        else
            "Hint: use --head-slots N and/or quote `N*host` tokens."
        end
    else
        head = "$(cmd): no workers"
        hint = if surface === :api
            "Hint: pass head_workers= and/or machine tokens (`N*host`)."
        else
            "Hint: use --head-workers N and/or quote `N*host` tokens."
        end
    end
    return join_explained_message(head, hint)
end

"""Reject removed `--local-workers` / `--local-slots` with head flag hints."""
function reject_legacy_local_placement_flag!(arg::AbstractString)
    a = String(arg)
    if a == "--local-workers" || startswith(a, "--local-workers=")
        throw(
            ArgumentError(
                join_explained_message(
                    "$(a) was removed",
                    "use --head-workers N on drive.",
                ),
            ),
        )
    end
    if a == "--local-slots" || startswith(a, "--local-slots=")
        throw(
            ArgumentError(
                join_explained_message(
                    "$(a) was removed",
                    "use --head-slots N on go.",
                ),
            ),
        )
    end
    return nothing
end

"""Reject `--head-workers` on go (use `--head-slots`)."""
function reject_go_head_workers_flag!()
    throw(
        ArgumentError(
            join_explained_message(
                "go does not accept --head-workers",
                "go uses --head-slots N for head-machine subprocess slots.",
            ),
        ),
    )
end

function _go_rejects_head_workers_arg(args::AbstractVector{<:AbstractString})::Bool
    for arg in args
        arg == "--head-workers" && return true
        arg == "--local-workers" && return true
    end
    return false
end

"""Scan argv before shared peel; go must not accept `--head-workers`."""
function assert_go_argv_no_head_workers!(args::AbstractVector{<:AbstractString})
    for arg in args
        reject_legacy_local_placement_flag!(String(arg))
    end
    _go_rejects_head_workers_arg(args) && reject_go_head_workers_flag!()
    return nothing
end

"""Reject `--head-slots` on drive."""
function reject_drive_ride_head_slots_flag!()
    throw(
        ArgumentError(
            join_explained_message(
                "this command does not accept --head-slots",
                "use --head-workers N for LocalManager workers on the head machine.",
            ),
        ),
    )
end

function _mistaken_short_p_flag(arg::AbstractString)::Bool
    s = String(arg)
    s == "-p" && return true
    return length(s) > 2 && s[1:2] == "-p" && s[3] != '-'
end

function _mistaken_short_l_flag(arg::AbstractString)::Bool
    s = String(arg)
    s == "-l" && return true
    s == "--local" && return true
    startswith(s, "-l:") && return true
    startswith(s, "--local:") && return true
    return length(s) > 2 && s[1:2] == "-l" && s[3] != '-' && s[3] != 'o'
end

function _mistaken_short_L_flag(arg::AbstractString)::Bool
    s = String(arg)
    s == "-L" && return true
    return length(s) > 2 && s[1:2] == "-L"
end

function _mistaken_short_flag_message(
        flag::AbstractString;
        command::Symbol,
        kind::Symbol,
    )::String
    cmd = string(command)
    if kind === :p
        if command === :go
            return join_explained_message(
                "unknown option $(flag)",
                "go has no `-p` short flag; use --head-slots N for head-machine slots. " *
                    "Put `host:port` and `user@host` in --hosts or a hosts file.",
            )
        end
        return join_explained_message(
            "unknown option $(flag); did you mean --head-workers N?",
            "Ports go in the hosts file as host:port.",
        )
    elseif kind === :l
        return join_explained_message(
            "unknown option $(flag)",
            "Put the SSH user in the hosts file as user@host (not a `-l` flag).",
        )
    elseif kind === :L
        return join_explained_message(
            "unknown option $(flag)",
            "Port forwarding is not supported here; use ssh config or a hosts file entry host:port.",
        )
    end
    return join_explained_message("unknown $(cmd) option: $(flag)", "Run `$(cli_m()) help $(cmd)` for flags.")
end

"""
Reject mistaken short flags `-p`, `-l`, `-L` (and glued forms like `-p4`) before
placement parsing. Does not treat them as worker counts.
"""
function reject_mistaken_short_placement_flags!(
        args::AbstractVector{<:AbstractString};
        command::Symbol,
    )::Nothing
    command in (:go, :drive) ||
        throw(ArgumentError("reject_mistaken_short_placement_flags!: unsupported command $(repr(command))"))
    for arg in args
        a = String(arg)
        reject_legacy_local_placement_flag!(a)
        if _mistaken_short_p_flag(a)
            throw(ArgumentError(_mistaken_short_flag_message(a; command = command, kind = :p)))
        elseif _mistaken_short_l_flag(a)
            throw(ArgumentError(_mistaken_short_flag_message(a; command = command, kind = :l)))
        elseif _mistaken_short_L_flag(a)
            throw(ArgumentError(_mistaken_short_flag_message(a; command = command, kind = :L)))
        end
    end
    return nothing
end

public assert_go_argv_no_head_workers!, format_kit_go_implicit_head_slot,
    format_kit_head_placement, format_kit_remote_placement, kit_head_host_label,
    kit_head_placement_role, reject_drive_ride_head_slots_flag!,
    reject_go_head_workers_flag!, reject_legacy_local_placement_flag!,
    reject_mistaken_short_placement_flags!, resolve_go_head_slots, zero_placement_usage_error
