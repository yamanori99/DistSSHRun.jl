# Local placement labels (drive / ride workers, go local slots).

"""Hostname of the machine running this DistSSHRun process (process 1)."""
function kit_local_host_label()::String
    return string(gethostname())
end

"""User-facing local placement line, e.g. `local: host, 2 workers`."""
function format_kit_local_placement(n::Integer, unit::AbstractString)::String
    return "local: $(kit_local_host_label()), $n $(unit)"
end

"""`go` with no hosts and no `--local-slots`: one implicit local slot."""
function format_kit_go_implicit_local_slot()::String
    return "local: $(kit_local_host_label()), 1 slot (no hosts given)"
end

"""
Resolve `go` local slot count.

Empty `host_tokens` and unset `local_slots` → one implicit local slot.
Empty hosts with explicit `local_slots=0` → zero (caller should error).
"""
function resolve_go_local_slots(
        host_tokens::AbstractVector{<:AbstractString},
        local_slots::Union{Nothing, Integer},
    )::Tuple{Int, Bool}
    if !isempty(host_tokens)
        n = local_slots === nothing ? 0 : Int(local_slots)
        n < 0 && throw(ArgumentError("--local-slots must be >= 0, got $n"))
        return n, false
    end
    if local_slots !== nothing
        n = Int(local_slots)
        n < 0 && throw(ArgumentError("--local-slots must be >= 0, got $n"))
        return n, false
    end
    return 1, true
end

"""Usage error when a job has no workers (drive / ride) or slots (go)."""
function zero_placement_usage_error(command::Symbol; surface::Symbol = :cli)::String
    surface = _normalize_hint_surface(surface)
    cmd = String(command)
    if command === :go
        head = "go: no execution slots"
        hint = if surface === :api
            "Hint: pass --local-slots N and/or machine tokens (`N*host`)."
        else
            "Hint: use --local-slots N and/or quote `N*host` tokens."
        end
    else
        head = "$(cmd): no workers"
        hint = if surface === :api
            "Hint: pass local_workers= and/or machine tokens (`N*host`)."
        else
            "Hint: use --local-workers N and/or quote `N*host` tokens."
        end
    end
    return join_explained_message(head, hint)
end

"""Reject `--local-workers` on go (use `--local-slots`)."""
function reject_go_local_workers_flag!()
    throw(
        ArgumentError(
            join_explained_message(
                "go does not accept --local-workers",
                "go uses --local-slots N for local subprocess slots on this machine.",
            ),
        ),
    )
end

function _go_rejects_local_workers_arg(args::AbstractVector{<:AbstractString})::Bool
    for arg in args
        arg == "--local-workers" && return true
    end
    return false
end

"""Scan argv before shared peel; go must not accept `--local-workers`."""
function assert_go_argv_no_local_workers!(args::AbstractVector{<:AbstractString})
    _go_rejects_local_workers_arg(args) && reject_go_local_workers_flag!()
    return nothing
end

public assert_go_argv_no_local_workers!, format_kit_go_implicit_local_slot,
    format_kit_local_placement, kit_local_host_label, reject_go_local_workers_flag!,
    resolve_go_local_slots, zero_placement_usage_error