# Julia-style placement tokens: `N*[user@]host[:port]` (worker count prefix).

const _MACHINE_TOKEN_HINT =
    "use `N*[user@]host[:port]` (quote `--hosts` so the shell does not glob `*`); bare host = 1 worker"

"""Normalized machine row after parse: worker count, SSH destination, optional port."""
struct MachinePlacement
    workers::Int
    dest::String
    port::Union{Nothing, Int}
end

MachinePlacement(workers::Integer, dest::AbstractString) =
    MachinePlacement(Int(workers), String(dest), nothing)

function _machine_check_controls(raw::AbstractString, shown::AbstractString)
    any(iscntrl, raw) &&
        throw(ArgumentError("$(shown): host token contains a control character"))
    return nothing
end

function _looks_like_legacy_placement(s::AbstractString)::Bool
    base = strip(s)
    base == PARENT_HOST_NAME && return true
    startswith(base, PARENT_HOST_NAME * ":") && return true
    startswith(base, CHILD_TOKEN_PREFIX) && return true
    return false
end

"""Reject removed `parent` / `` tokens."""
function throw_legacy_machine_token(raw::AbstractString)
    s = String(raw)
    if _looks_like_legacy_placement(s)
        if startswith(s, CHILD_TOKEN_PREFIX) || s == PARENT_HOST_NAME || startswith(s, PARENT_HOST_NAME * ":")
            throw(
                ArgumentError(
                    "$(repr(s)) was removed; use --head-workers on drive/ride, --head-slots on go; "
                        * _MACHINE_TOKEN_HINT,
                ),
            )
        end
    end
    throw_legacy_placement_token(s)
    return nothing
end

function _split_bracketed_ipv6_port(
        prefix::AbstractString,
        hostpart::AbstractString,
        shown::AbstractString,
    )::Tuple{String, Union{Nothing, Int}}
    close = findfirst(']', String(hostpart))
    close === nothing &&
        throw(ArgumentError("$(repr(shown)): unclosed IPv6 bracket; use `[::1]` or `[fe80::1]:port`"))
    body = string(prefix, hostpart[1:close])
    rest = hostpart[(close + 1):end]
    if isempty(rest)
        return body, nothing
    end
    rest[1] != ':' &&
        throw(ArgumentError("$(repr(shown)): expected `:port` after `]`"))
    port = try
        parse(Int, rest[2:end])
    catch
        throw(ArgumentError("$(repr(shown)): SSH port must be an integer"))
    end
    port < 1 && throw(ArgumentError("$(repr(shown)): SSH port must be >= 1"))
    return body, port
end

"""Split `dest` into host body and optional SSH port (`:` after `]` or bare host)."""
function _split_ssh_port(dest::AbstractString)::Tuple{String, Union{Nothing, Int}}
    d = String(strip(dest))
    isempty(d) && throw(ArgumentError("empty SSH host in placement token"))
    if startswith(d, "[")
        return _split_bracketed_ipv6_port("", d, dest)
    end
    at = findlast('@', d)
    prefix = at === nothing ? "" : d[1:at]
    hostpart = at === nothing ? d : d[(at + 1):end]
    if startswith(hostpart, "[")
        return _split_bracketed_ipv6_port(prefix, hostpart, dest)
    end
    colon = findlast(':', hostpart)
    if colon === nothing
        validate_ssh_host(d; shown = dest)
        return d, nothing
    end
    port_str = hostpart[(colon + 1):end]
    port = try
        parse(Int, port_str)
    catch
        throw(ArgumentError("$(repr(dest)): SSH port must be an integer"))
    end
    port < 1 && throw(ArgumentError("$(repr(dest)): SSH port must be >= 1"))
    host_with_port = d[1:(length(d) - length(port_str) - 1)]
    validate_ssh_host(host_with_port; shown = dest)
    return host_with_port, port
end

"""
    parse_machine_token(spec) -> MachinePlacement

Parse `N*[user@]host[:port]`. Bare host (no `*`) means one worker.
Control characters are rejected before stripping.
"""
function parse_machine_token(spec::AbstractString)::MachinePlacement
    raw = String(spec)
    _machine_check_controls(raw, repr(spec))
    s = strip(raw)
    isempty(s) && throw(ArgumentError("empty host token"))
    throw_legacy_machine_token(s)
    star = findfirst('*', s)
    workers = 1
    rest = s
    if star !== nothing
        count_str = s[1:(star - 1)]
        rest = s[(star + 1):end]
        isempty(count_str) &&
            throw(ArgumentError("$(repr(spec)): missing worker count before `*`"))
        workers = try
            parse(Int, count_str)
        catch
            throw(ArgumentError("$(repr(spec)): worker count before `*` must be an integer"))
        end
        workers < 1 &&
            throw(ArgumentError("$(repr(spec)): worker count must be >= 1, got $workers"))
        isempty(strip(rest)) &&
            throw(ArgumentError("$(repr(spec)): missing host after `*`"))
    end
    dest, port = _split_ssh_port(rest)
    if workers == 1 && star === nothing && isfile(s) && !contains(s, '@') && !startswith(s, "[")
        throw(
            ArgumentError(
                "$(repr(spec)): looks like a local path, not an SSH host; quote the token "
                    * "or use an explicit count (e.g. `1*$(s)`). $_MACHINE_TOKEN_HINT",
            ),
        )
    end
    return MachinePlacement(workers, dest, port)
end

"""Canonical SSH destination for launch, SSH, placement `name`, and duplicate keys."""
function machine_ssh_endpoint(p::MachinePlacement)::String
    if p.port === nothing
        return p.dest
    end
    return string(p.dest, ":", p.port)
end

"""
Parse a bare SSH endpoint (`[user@]host[:port]`) into OpenSSH `dest` and optional port.

Worker-count prefixes (`N*…`) are rejected; use machine tokens for those.
"""
function parse_ssh_endpoint(endpoint::AbstractString)::Tuple{String, Union{Nothing, Int}}
    ep = String(strip(endpoint))
    isempty(ep) && throw(ArgumentError("empty SSH endpoint"))
    occursin('*', ep) &&
        throw(ArgumentError("$(repr(endpoint)): worker count prefix is not allowed in an SSH endpoint"))
    dest, port = _split_ssh_port(ep)
    validate_ssh_host(dest; shown = endpoint)
    return dest, port
end

"""SSH host label for duplicate detection (includes explicit `:port` when set)."""
function machine_ssh_label(p::MachinePlacement)::String
    d = p.dest
    at = findlast('@', d)
    hostpart = at === nothing ? d : d[(at + 1):end]
    if startswith(hostpart, "[")
        label = hostpart
        p.port === nothing && return label
        return string(label, ":", p.port)
    end
    colon = findfirst(':', hostpart)
    label = colon === nothing ? hostpart : hostpart[1:(colon - 1)]
    p.port === nothing && return label
    return string(label, ":", p.port)
end

"""Format a placement token; `format → parse` is identity for accepted tokens."""
function format_machine_token(p::MachinePlacement)::String
    dest = p.dest
    if p.port !== nothing
        dest = string(dest, ":", p.port)
    end
    p.workers == 1 && return dest
    return string(p.workers, "*", dest)
end

function format_machine_token(workers::Integer, dest::AbstractString; port::Union{Nothing, Integer} = nothing)::String
    d = String(dest)
    body, parsed_port = _split_ssh_port(d)
    use_port = port !== nothing ? Int(port) : parsed_port
    return format_machine_token(MachinePlacement(Int(workers), body, use_port))
end

function _machine_placement_hostpart(dest::AbstractString)::String
    d = String(dest)
    at = findlast('@', d)
    hostpart = at === nothing ? d : d[(at + 1):end]
    if startswith(hostpart, "[") && endswith(hostpart, "]")
        return hostpart[2:(end - 1)]
    end
    return hostpart
end

"""Map a machine token to the legacy placement tuple used by drive/go pipelines."""
function machine_to_placement_token(spec::AbstractString)::NamedTuple{(:role, :name, :n), Tuple{Symbol, String, Union{Nothing, Int}}}
    p = parse_machine_token(spec)
    validate_ssh_host(p.dest; shown = spec)
    is_parent_host_name(_machine_placement_hostpart(p.dest)) &&
        throw(ArgumentError("$(repr(spec)): `parent` is not an SSH host; use --head-workers"))
    name = machine_ssh_endpoint(p)
    return (role = :child, name = name, n = p.workers)
end
