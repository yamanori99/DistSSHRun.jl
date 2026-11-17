# Launch topology and bind validation (#461).

const _LOOPBACK_BINDS = ("127.0.0.1", "localhost", "::1")

function _is_loopback_bind(addr::AbstractString)::Bool
    a = lowercase(String(strip(addr)))
    return a in _LOOPBACK_BINDS || startswith(a, "127.")
end

"""
Per-host SSH launch view (bind address, tunnel flag, resolved topology).

Built by [`validate_host_launch_plan`](@ref). Field names are API for 0.2.0:
`host`, `bind`, `tunnel`, `topology` (`:master_worker` or `:all_to_all`).
"""
struct HostLaunchPlan
    host::String
    bind::String
    tunnel::Bool
    topology::Symbol
end

"""
Resolve `DISTSSH_TOPOLOGY` (`auto` or `master_worker`; env may spell `master-worker`).

Throws `ArgumentError` on any other value.
"""
function resolved_topology(env_val::AbstractString = get(ENV, "DISTSSH_TOPOLOGY", "auto"))::Symbol
    v = lowercase(String(strip(env_val)))
    v == "auto" && return :auto
    v in ("master_worker", "master-worker") && return :master_worker
    throw(ArgumentError("DISTSSH_TOPOLOGY must be auto or master_worker, got $(repr(env_val))"))
end

"""
Effective Distributed topology for launch: `auto` → `master_worker` or `all_to_all`
when [`unsafe_all_to_all_active`](@ref); fixed `master_worker` rejects `unsafe_all_to_all`.
"""
function topology_for_launch(;
        unsafe_all_to_all::Bool = unsafe_all_to_all_active(),
        topology_setting::Union{Nothing, AbstractString} = nothing,
    )::Symbol
    t = if topology_setting === nothing
        resolved_topology()
    else
        resolved_topology(String(topology_setting))
    end
    t === :auto && return unsafe_all_to_all ? :all_to_all : :master_worker
    unsafe_all_to_all && throw(
        ArgumentError(
            "unsafe_all_to_all requires DISTSSH_TOPOLOGY=auto; worker-to-worker links need the opt-in flag",
        ),
    )
    return t
end

function default_bind_address(host::AbstractString)::String
    String(host) == PARENT_HOST_NAME && return "127.0.0.1"
    return "127.0.0.1"
end

"""Loopback default, or a TOML hosts-file `bind` when `overrides` names the host."""
function resolved_bind_address(
        host::AbstractString,
        overrides::AbstractDict{<:AbstractString, <:AbstractString},
    )::String
    h = String(host)
    return haskey(overrides, h) ? String(strip(overrides[h])) : default_bind_address(h)
end

function _toml_bind_map_from_hosts_file(
        hosts_file::Union{Nothing, AbstractString};
        surface::Symbol = :cli,
    )::Dict{String, String}
    hosts_file === nothing && return Dict{String, String}()
    path = canonical_local_path(String(strip(hosts_file)))
    hosts_file_is_toml(path) || return Dict{String, String}()
    return read_toml_host_bind_overrides(path; surface = surface)
end

"""
Merge TOML `[[hosts]]` `bind` values with an optional `bind_overrides=` map.

Conflicting values for the same SSH destination are rejected (no precedence
guessing). Keys only in `bind_overrides=` are kept when absent from the file.
"""
function resolve_launch_bind_overrides(;
        hosts_file::Union{Nothing, AbstractString} = nothing,
        bind_overrides::AbstractDict{<:AbstractString, <:AbstractString} = Dict{String, String}(),
        surface::Symbol = :cli,
    )::Dict{String, String}
    from_file = if hosts_file === nothing
        Dict{String, String}()
    else
        _toml_bind_map_from_hosts_file(hosts_file; surface = surface)
    end
    merged = copy(from_file)
    for (host, bind) in bind_overrides
        h = String(host)
        b = String(strip(bind))
        if haskey(from_file, h) && from_file[h] != b
            throw(
                ArgumentError(
                    join_explained_message(
                        "$(repr(h)): bind_overrides= $(repr(b)) conflicts with hosts file $(repr(from_file[h]))",
                        "Hint: set per-host bind only in the TOML hosts file or only in bind_overrides=, not both",
                    ),
                ),
            )
        end
        merged[h] = b
    end
    return merged
end

"""
Reject remote `tunnel=false` with loopback bind before launch.

`unsafe_expose_port` is required when bind is not loopback.
"""
function validate_host_launch_plan(
        host::AbstractString,
        bind::AbstractString;
        tunnel::Bool = ssh_tunnel_enabled(),
        unsafe_expose_port::Bool = unsafe_expose_port_active(),
        unsafe_all_to_all::Bool = unsafe_all_to_all_active(),
        topology_setting::Union{Nothing, AbstractString} = nothing,
    )::HostLaunchPlan
    h = String(host)
    b = String(strip(bind))
    isempty(b) && throw(ArgumentError("$(repr(h)): empty bind address"))
    !tunnel && h != PARENT_HOST_NAME && _is_loopback_bind(b) && throw(
        ArgumentError(
            join_explained_message(
                "$(repr(h)): SSH tunnel is off but bind is $(repr(b))",
                "Hint: enable tunnel (default) or set a non-loopback bind with --unsafe-expose-port",
            ),
        ),
    )
    !_is_loopback_bind(b) && !unsafe_expose_port && throw(
        ArgumentError(
            join_explained_message(
                "$(repr(h)): non-loopback bind $(repr(b))",
                "Hint: pass --unsafe-expose-port to expose the worker port beyond loopback",
            ),
        ),
    )
    top = topology_for_launch(;
        unsafe_all_to_all = unsafe_all_to_all,
        topology_setting = topology_setting,
    )
    return HostLaunchPlan(h, b, tunnel, top)
end

"""One-line dry-run summary for a host."""
function format_host_launch_plan_line(plan::HostLaunchPlan)::String
    return "$(plan.host): topology=$(plan.topology) bind=$(plan.bind) tunnel=$(plan.tunnel)"
end

public HostLaunchPlan, default_bind_address, format_host_launch_plan_line, resolve_launch_bind_overrides
public resolved_bind_address, resolved_topology, topology_for_launch, validate_host_launch_plan
