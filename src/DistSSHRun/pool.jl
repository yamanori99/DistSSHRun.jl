# Cluster inventory: cores / RAM + fail-closed health. No slot estimate.

"""One host in a [`ResourcePool`](@ref). Missing numbers are `nothing`, not `0`."""
struct HostInventory
    host::String
    ok::Bool
    nproc::Union{Nothing, Int}
    total_gb::Union{Nothing, Float64}
    message::String
end

"""
Cluster view of listed hosts: totals plus per-host health.

`ok` is false if any listed host failed the probe (fail-closed). `cores` and
`gb` sum **reachable** hosts that reported that field; failed rows stay in
`hosts`. Does not change `go` / `drive` `--best-effort`.
"""
struct ResourcePool
    ok::Bool
    hosts::Vector{HostInventory}
    cores::Union{Nothing, Int}
    gb::Union{Nothing, Float64}
end

function Base.show(io::IO, pool::ResourcePool)
    print(
        io,
        "ResourcePool(ok=",
        pool.ok,
        ", cores=",
        pool.cores === nothing ? "-" : string(pool.cores),
        ", hosts=",
        length(pool.hosts),
        ")",
    )
    return nothing
end

function _gb_from_bytes(bytes::Union{Nothing, UInt64})::Union{Nothing, Float64}
    bytes === nothing && return nothing
    return Float64(bytes) / 1024^3
end

function _inventory_from_facts(facts::HostFacts)::HostInventory
    msg = facts.reachable ? (facts.error === nothing ? "ok" : facts.error) :
        something(facts.error, "unreachable")
    return HostInventory(
        facts.identity,
        facts.reachable && facts.error === nothing,
        facts.ncpu,
        _gb_from_bytes(facts.total_memory_bytes),
        msg,
    )
end

function _sum_present(vals)::Union{Nothing, Int}
    acc = 0
    any = false
    for v in vals
        v === nothing && continue
        any = true
        acc += v
    end
    return any ? acc : nothing
end

function _sum_present_f(vals)::Union{Nothing, Float64}
    acc = 0.0
    any = false
    for v in vals
        v === nothing && continue
        any = true
        acc += v
    end
    return any ? acc : nothing
end

"""
    pool!(session) -> ResourcePool

Probe listed hosts for cores and RAM via [`collect_host_facts`](@ref).
Unreachable hosts stay in the list with `ok=false`. The pool is `ok` only
when every listed host probed successfully. Does not start workers.
"""
function pool!(session::KitSession)::ResourcePool
    parsed = parse_worker_tokens(session.tokens)
    want_parent = session.include_parent_for_size ||
        parsed.parent_autosize || parsed.parent_workers > 0
    all_hosts = String[]
    want_parent && push!(all_hosts, PARENT_HOST_NAME)
    append!(all_hosts, session.hosts)
    isempty(all_hosts) && throw(
        ArgumentError(
            explain_no_hosts(; surface = hint_surface(session), kind = :pool),
        )
    )
    return _with_kit_inproc_run!(:pool) do
        apply_session_env!(session)
        rows = HostInventory[_inventory_from_facts(f) for f in collect_host_facts(all_hosts)]
        healthy = [r for r in rows if r.ok]
        cores = _sum_present(r.nproc for r in healthy)
        gb = _sum_present_f(r.total_gb for r in healthy)
        return ResourcePool(all(r -> r.ok, rows), rows, cores, gb)
    end
end

function _fmt_cores(n::Union{Nothing, Int})::String
    n === nothing && return "-"
    return string(n, " cores")
end

function _fmt_gb(g::Union{Nothing, Float64})::String
    g === nothing && return "-"
    return string(round(g; digits = 1), " GB")
end

"""Print cluster totals first, then per-host health. Always writes `io` (stdout)."""
function print_pool(pool::ResourcePool; io::IO = stdout)
    failed = count(r -> !r.ok, pool.hosts)
    extra = failed == 0 ? "" : "  ($failed host$(failed == 1 ? "" : "s") unreachable)"
    println(io, "Pool: $(_fmt_cores(pool.cores))  $(_fmt_gb(pool.gb))$extra")
    for row in pool.hosts
        shown = is_parent_host_name(row.host) ? PARENT_HOST_NAME : row.host
        if row.ok
            println(
                io,
                "  $(rpad(shown, 16)) ok    $(_fmt_cores(row.nproc))  $(_fmt_gb(row.total_gb))",
            )
        else
            println(io, "  $(rpad(shown, 16)) fail  $(row.message)")
        end
    end
    return nothing
end
