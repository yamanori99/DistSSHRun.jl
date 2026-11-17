# Launch topology and bind validation (#461, #503).

"""SSH destination key for per-host bind lookup (strips worker-count prefix)."""
function launch_bind_host_key(host_or_token::AbstractString)::String
    return split_worker_token(String(host_or_token))[1]
end

function _validated_bind_literal(raw::AbstractString, where::Union{Nothing, AbstractString} = nothing)
    lit = try
        parse_bind_ipv4_literal(raw)
    catch e
        e isa ArgumentError || rethrow()
        if where === nothing
            rethrow()
        end
        throw(ArgumentError(replace(e.msg, r"^bind " => "$(where): bind ")))
    end
    return lit
end

function _toml_bind_map_from_hosts_file(
        hosts_file::Union{Nothing, AbstractString};
        surface::Symbol = :cli,
        reject_bind_for_command::Union{Nothing, Symbol} = nothing,
    )::Dict{String, String}
    hosts_file === nothing && return Dict{String, String}()
    path = canonical_local_path(String(strip(hosts_file)))
    hosts_file_is_toml(path) || return Dict{String, String}()
    out = Dict{String, String}()
    for (i, entry) in enumerate(read_toml_host_entries(path; surface = surface))
        entry.bind === nothing && continue
        dest = toml_host_ssh_dest(entry)
        ctx = "$(path): hosts[$i] ($(dest))"
        if reject_bind_for_command === :go
            throw(
                ArgumentError(
                    "$ctx: bind is not supported for go; checked: go launch contract; fix: remove bind or use drive/ride",
                ),
            )
        end
        lit = _validated_bind_literal(entry.bind, ctx)
        out[dest] = lit.canonical
    end
    return out
end

"""
Merge TOML `[[hosts]]` `bind` values with an optional `bind_overrides=` map.

Conflicting values for the same SSH destination are rejected (canonical compare).
Keys in `bind_overrides=` that match no planned host are rejected.
"""
function resolve_launch_bind_overrides(;
        hosts_file::Union{Nothing, AbstractString} = nothing,
        bind_overrides::AbstractDict{<:AbstractString, <:AbstractString} = Dict{String, String}(),
        surface::Symbol = :cli,
        planned_hosts::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
        command::Union{Nothing, Symbol} = nothing,
    )::Dict{String, String}
    from_file = if hosts_file === nothing
        Dict{String, String}()
    else
        _toml_bind_map_from_hosts_file(
            hosts_file;
            surface = surface,
            reject_bind_for_command = command,
        )
    end
    merged = copy(from_file)
    known = planned_hosts === nothing ? nothing : String[launch_bind_host_key(h) for h in planned_hosts]
    for (host, bind) in bind_overrides
        h = launch_bind_host_key(host)
        if known !== nothing && !(h in known)
            listed = join(sort(known), ", ")
            throw(
                ArgumentError(
                    join_explained_message(
                        "$(repr(h)): bind_overrides= matches no planned host (known: $listed)",
                        "Hint: bind_overrides= keys must match a listed SSH destination",
                    ),
                ),
            )
        end
        b = String(strip(bind))
        lit = _validated_bind_literal(b, repr(h))
        if haskey(from_file, h)
            file_lit = parse_bind_ipv4_literal(from_file[h])
            file_lit.canonical != lit.canonical && throw(
                ArgumentError(
                    join_explained_message(
                        "$(repr(h)): bind_overrides= $(repr(lit.canonical)) conflicts with hosts file $(repr(file_lit.canonical))",
                        "Hint: set per-host bind only in the TOML hosts file or only in bind_overrides=, not both",
                    ),
                ),
            )
        end
        merged[h] = lit.canonical
    end
    return merged
end

function default_bind_address(host::AbstractString)::String
    String(host) == PARENT_HOST_NAME && return "127.0.0.1"
    return "127.0.0.1"
end

"""Loopback default, or a validated TOML / override bind when the host key matches."""
function resolved_bind_address(
        host_or_token::AbstractString,
        overrides::AbstractDict{<:AbstractString, <:AbstractString},
    )::String
    h = launch_bind_host_key(host_or_token)
    return haskey(overrides, h) ? String(overrides[h]) : default_bind_address(h)
end

"""
Per-host SSH launch view (bind address, tunnel flag, resolved topology).

Field names are API for 0.2.0: `host`, `bind`, `tunnel`, `topology`
(`:master_worker` or `:all_to_all`). `bind` is the canonical IPv4 literal passed to
Distributed (or the dry-run display string for `0.0.0.0`).
"""
struct HostLaunchPlan
    host::String
    bind::String
    tunnel::Bool
    topology::Symbol
end

function resolved_topology(env_val::AbstractString = get(ENV, "DISTSSH_TOPOLOGY", "auto"))::Symbol
    v = lowercase(String(strip(env_val)))
    v == "auto" && return :auto
    v == "master_worker" && return :master_worker
    throw(
        ArgumentError(
            join_explained_message(
                "DISTSSH_TOPOLOGY must be auto or master_worker, got $(repr(env_val))",
                "Hint: set DISTSSH_TOPOLOGY=master_worker",
            ),
        ),
    )
end

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

function validate_host_launch_plan(
        host::AbstractString,
        bind::AbstractString;
        tunnel::Bool = ssh_tunnel_enabled(),
        unsafe_expose_port::Bool = unsafe_expose_port_active(),
        unsafe_all_to_all::Bool = unsafe_all_to_all_active(),
        topology_setting::Union{Nothing, AbstractString} = nothing,
    )::HostLaunchPlan
    h = launch_bind_host_key(host)
    lit = parse_bind_ipv4_literal(bind)
    if lit.all_interfaces
        (!unsafe_expose_port || !tunnel) && throw(
            ArgumentError(
                join_explained_message(
                    "$(repr(h)): bind 0.0.0.0 requires --unsafe-expose-port and SSH tunnel enabled",
                    "Hint: pass --unsafe-expose-port and keep tunnel enabled (default)",
                ),
            ),
        )
    elseif !tunnel && h != PARENT_HOST_NAME && lit.loopback
        throw(
            ArgumentError(
                join_explained_message(
                    "$(repr(h)): SSH tunnel is off but bind is $(repr(lit.canonical))",
                    "Hint: enable tunnel (default) or set a non-loopback bind with --unsafe-expose-port",
                ),
            ),
        )
    elseif !lit.loopback && !unsafe_expose_port
        throw(
            ArgumentError(
                join_explained_message(
                    "$(repr(h)): non-loopback bind $(repr(lit.canonical))",
                    "Hint: pass --unsafe-expose-port to expose the worker port beyond loopback",
                ),
            ),
        )
    end
    top = topology_for_launch(;
        unsafe_all_to_all = unsafe_all_to_all,
        topology_setting = topology_setting,
    )
    disp = bind_dry_run_display(lit)
    return HostLaunchPlan(h, disp, tunnel, top)
end

"""
    validate_all_host_launch_plans!(ssh_hosts, bind_overrides; kwargs...) -> Vector{HostLaunchPlan}

Validate bind/tunnel/topology for every listed SSH host before any SSH connect.
Same logic as `--dry-run` launch section.
"""
function validate_all_host_launch_plans!(
        ssh_hosts::AbstractVector{<:AbstractString},
        bind_overrides::AbstractDict{<:AbstractString, <:AbstractString};
        tunnel::Bool = ssh_tunnel_enabled(),
        unsafe_expose_port::Bool = unsafe_expose_port_active(),
        unsafe_all_to_all::Bool = unsafe_all_to_all_active(),
        topology_setting::Union{Nothing, AbstractString} = nothing,
    )::Vector{HostLaunchPlan}
    plans = HostLaunchPlan[]
    for host in ssh_hosts
        raw = resolved_bind_address(host, bind_overrides)
        push!(
            plans,
            validate_host_launch_plan(
                host,
                raw;
                tunnel = tunnel,
                unsafe_expose_port = unsafe_expose_port,
                unsafe_all_to_all = unsafe_all_to_all,
                topology_setting = topology_setting,
            ),
        )
    end
    return plans
end

"""One-line dry-run summary for a host."""
function format_host_launch_plan_line(plan::HostLaunchPlan)::String
    return "$(plan.host): topology=$(plan.topology) bind=$(plan.bind) tunnel=$(plan.tunnel)"
end

"""CLI usage text for a bind config `ArgumentError` (lowercase lead-in)."""
function _bind_config_cli_message(msg::AbstractString)::String
    line = first(split(String(msg), '\n'; limit = 2))
    lower = lowercase(line)
    occursin("hint:", lowercase(msg)) && return lower
    return string(lower, "\nHint: pass --help for usage")
end

public HostLaunchPlan
public launch_bind_host_key, validate_all_host_launch_plans!