"""
Rebuild a placement SSH endpoint from `WorkerConfig.host` and worker `sshflags`.

`WorkerConfig.host` holds Distributed's machine host string from [`ssh_addprocs_machine`](@ref).
Returns `nothing` when the host cannot be parsed as a supported endpoint (including IPv6 literals).
"""
function placement_ssh_endpoint_from_worker_host(
        worker_host::AbstractString,
        sshflags::Union{Nothing, Cmd} = `ssh`,
    )::Union{Nothing, String}
    openssh = String(strip(worker_host))
    isempty(openssh) && return nothing
    flags = sshflags === nothing ? `ssh` : sshflags
    flags_port = explicit_port_from_sshflags(flags)
    try
        _, port = parse_ssh_endpoint(openssh)
        if port === nothing && flags_port !== nothing
            ep = string(openssh, ":", flags_port)
            parse_ssh_endpoint(ep)
            return ep
        end
        return openssh
    catch
        return nothing
    end
end
