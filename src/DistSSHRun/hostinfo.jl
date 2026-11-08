# hostinfo CLI helpers. Facts and print_hostinfo live in DistSSHBase.

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
