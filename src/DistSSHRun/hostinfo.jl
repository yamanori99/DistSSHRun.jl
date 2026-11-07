# hostinfo CLI: format DistSSHBase.HostFacts. Collection stays in Base.

function session_inventory_hosts(session::KitSession)::Vector{String}
    parsed = parse_worker_tokens(session.tokens)
    want_parent = session.include_parent_for_size ||
        parsed.parent_autosize || parsed.parent_workers > 0
    all_hosts = String[]
    want_parent && push!(all_hosts, PARENT_HOST_NAME)
    append!(all_hosts, session.hosts)
    return all_hosts
end

"""SSH host names used for pool / hostinfo (`parent` first when included)."""
function session_size_hosts(session::KitSession)::Tuple{Vector{String}, Vector{String}}
    child_hosts = copy(session.hosts)
    all_hosts = session_inventory_hosts(session)
    return all_hosts, child_hosts
end

function _hostinfo_dash(x)::String
    x === nothing && return "-"
    return string(x)
end

function _hostinfo_gb(bytes::Union{Nothing, UInt64})::String
    bytes === nothing && return "-"
    return string(round(Float64(bytes) / 1024^3; digits = 1), " GB")
end

"""Print host facts. Always writes `io` (requested results, including `--quiet`)."""
function print_hostinfo(rows::AbstractVector{HostFacts}; io::IO = stdout)
    failed = count(r -> !r.reachable, rows)
    extra = failed == 0 ? "" : "  ($failed host$(failed == 1 ? "" : "s") failed)"
    println(io, "Hostinfo: $(length(rows)) host$(length(rows) == 1 ? "" : "s")$extra")
    for row in rows
        shown = is_parent_host_name(row.identity) ? PARENT_HOST_NAME : row.identity
        if !row.reachable
            println(io, "  $(rpad(shown, 16)) fail  $(something(row.error, "unreachable"))")
            continue
        end
        println(
            io,
            "  $(rpad(shown, 16)) ok    ",
            _hostinfo_dash(row.os), "  ",
            row.ncpu === nothing ? "- cores" : "$(row.ncpu) cores", "  ",
            _hostinfo_gb(row.total_memory_bytes), "  ",
            _hostinfo_dash(row.julia_version), "  ",
            _hostinfo_dash(row.julia_exe),
        )
        if row.error !== nothing
            println(io, "    note: $(row.error)")
        end
    end
    return nothing
end
