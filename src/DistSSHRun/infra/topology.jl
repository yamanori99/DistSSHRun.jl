# Launch topology and bind validation (#461).

const _LOOPBACK_BINDS = ("127.0.0.1", "localhost", "::1")

function _is_loopback_bind(addr::AbstractString)::Bool
    a = lowercase(String(strip(addr)))
    return a in _LOOPBACK_BINDS || startswith(a, "127.")
end

"""Per-host SSH launch view (bind + tunnel + topology)."""
struct HostLaunchPlan
    host::String
    bind::String
    tunnel::Bool
    topology::Symbol
end

function resolved_topology(env_val::AbstractString = get(ENV, "DISTSSH_TOPOLOGY", "auto"))::Symbol
    v = lowercase(String(strip(env_val)))
    v == "auto" && return :auto
    v in ("master_worker", "master-worker") && return :master_worker
    throw(ArgumentError("DISTSSH_TOPOLOGY must be auto or master_worker, got $(repr(env_val))"))
end

function topology_for_launch(; unsafe_all_to_all::Bool = false)::Symbol
    t = resolved_topology()
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

"""
Reject remote `tunnel=false` with loopback bind before launch.

`unsafe_expose_port` is required when bind is not loopback.
"""
function validate_host_launch_plan(
        host::AbstractString,
        bind::AbstractString;
        tunnel::Bool = ssh_tunnel_enabled(),
        unsafe_expose_port::Bool = false,
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
    top = topology_for_launch(; unsafe_all_to_all = unsafe_all_to_all_active())
    return HostLaunchPlan(h, b, tunnel, top)
end

"""One-line dry-run summary for a host."""
function format_host_launch_plan_line(plan::HostLaunchPlan)::String
    return "$(plan.host): topology=$(plan.topology) bind=$(plan.bind) tunnel=$(plan.tunnel)"
end
