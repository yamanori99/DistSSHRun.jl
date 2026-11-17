# Strict Distributed bind literals (#503). Does not use `parse(IPv4)`.

"""Parsed canonical IPv4 bind literal for launch."""
struct BindIPv4Literal
    canonical::String
    loopback::Bool
    all_interfaces::Bool
end

function _bind_octet_invalid_reason(part::AbstractString)::Union{Nothing, String}
    isempty(part) && return "is empty (need four decimal parts 0-255)"
    part[1] == '-' && return "must not contain a sign"
    part[1] == '+' && return "must not contain a sign"
    length(part) > 1 && part[1] == '0' && return "must not use leading zeros"
    for c in part
        if '0' <= c <= '9'
            continue
        end
        return occursin(r"[A-Za-z]", part) ? "host names are not resolved" : "must use decimal digits only"
    end
    n = parse(Int, part; base = 10)
    n > 255 && return "exceeds 255"
    return nothing
end

function _reject_bind_whitespace(raw::AbstractString)
    s = String(raw)
    s != strip(s) && throw(ArgumentError("bind $(repr(raw)) must not contain leading or trailing whitespace"))
    for c in s
        isspace(c) && throw(ArgumentError("bind $(repr(raw)) must not contain whitespace"))
    end
    return s
end

const _BIND_FIX_LOOPBACK = "bind = \"127.0.0.1\""
const _BIND_CHECK_IPV4 = "dotted-quad IPv4 literal"
const _BIND_CHECK_IPV4_NAMES = "dotted-quad IPv4 literal (names are not resolved)"

function _reject_non_ipv4_bind_shape(raw::AbstractString)
    s = _reject_bind_whitespace(raw)
    isempty(s) &&
        throw(ArgumentError("bind is empty; checked: $_BIND_CHECK_IPV4; fix: $_BIND_FIX_LOOPBACK"))
    if !occursin('.', s) && occursin(r"[A-Za-z]", s)
        throw(
            ArgumentError(
                "bind $(repr(raw)) is not an IPv4 address; checked: $_BIND_CHECK_IPV4_NAMES; fix: $_BIND_FIX_LOOPBACK",
            ),
        )
    end
    if occursin(':', s) || occursin('[', s) || occursin(']', s) || occursin('%', s)
        throw(
            ArgumentError(
                "bind $(repr(raw)) is not an IPv4 address; checked: dotted-quad IPv4 literal (IPv6 is not supported); fix: bind = \"127.0.0.1\"",
            ),
        )
    end
    if occursin('/', s)
        throw(
            ArgumentError(
                "bind $(repr(raw)) is not an IPv4 address; checked: dotted-quad IPv4 literal (CIDR is not supported); fix: bind = \"127.0.0.1\"",
            ),
        )
    end
    return s
end

function _classify_bind_octets(o1::Int, o2::Int, o3::Int, o4::Int)
    all_interfaces = o1 == 0 && o2 == 0 && o3 == 0 && o4 == 0
    loopback = o1 == 127
    multicast = 224 <= o1 <= 239
    reserved = 240 <= o1 <= 254
    broadcast = o1 == 255 && o2 == 255 && o3 == 255 && o4 == 255
    return (all_interfaces, loopback, multicast, reserved, broadcast)
end

"""
    parse_bind_ipv4_literal(raw::AbstractString) -> BindIPv4Literal

Accept only canonical dotted-quad IPv4 (decimal, 0-255, no leading zeros, no
signs, exactly four parts). Rejects host names, ports, IPv6, and whitespace.
"""
function parse_bind_ipv4_literal(raw::AbstractString)::BindIPv4Literal
    s = _reject_non_ipv4_bind_shape(raw)
    parts = split(s, '.')
    length(parts) != 4 && throw(
        ArgumentError(
            "bind $(repr(raw)) is not an IPv4 address; checked: dotted-quad IPv4 literal (need four decimal parts); fix: bind = \"127.0.0.1\"",
        ),
    )
    octets = Int[]
    for part in parts
        why = _bind_octet_invalid_reason(part)
        why !== nothing && throw(
            ArgumentError(
                "bind $(repr(raw)) is not an IPv4 address; checked: dotted-quad IPv4 literal ($why); fix: bind = \"127.0.0.1\"",
            ),
        )
        push!(octets, parse(Int, part; base = 10))
    end
    o1, o2, o3, o4 = octets
    all_if, loopback, multicast, reserved, broadcast = _classify_bind_octets(o1, o2, o3, o4)
    broadcast && throw(
        ArgumentError(
            "bind $(repr(raw)) is a broadcast address; checked: dotted-quad IPv4 unicast literal; fix: bind = \"127.0.0.1\"",
        ),
    )
    multicast && throw(
        ArgumentError(
            "bind $(repr(raw)) is a multicast address; checked: dotted-quad IPv4 unicast literal; fix: bind = \"127.0.0.1\"",
        ),
    )
    reserved && throw(
        ArgumentError(
            "bind $(repr(raw)) is a reserved address; checked: dotted-quad IPv4 unicast literal; fix: bind = \"127.0.0.1\"",
        ),
    )
    # Unqualified dotted quad with non-numeric labels (e.g. localhost, 127.evil.host).
    canonical = join(string.(octets), '.')
    return BindIPv4Literal(canonical, loopback, all_if)
end

function _toml_bind_context(path::AbstractString, index::Int, dest::AbstractString)::String
    return "$(path): hosts[$index] ($(dest))"
end

"""Read and validate a TOML `bind` field (must be a string when present)."""
function read_toml_bind_string(row::Dict{String, Any}, path::AbstractString, index::Int, dest::AbstractString)::Union{Nothing, String}
    haskey(row, "bind") || return nothing
    b = get(row, "bind", nothing)
    b === nothing && return nothing
    ctx = _toml_bind_context(path, index, dest)
    b isa AbstractString || throw(
        ArgumentError(
            "$ctx: bind must be a string, got $(typeof(b)); checked: TOML bind field; fix: bind = \"127.0.0.1\"",
        ),
    )
    raw = String(b)
    _reject_bind_whitespace(raw)
    isempty(strip(raw)) && throw(
        ArgumentError(
            "$ctx: bind is empty; checked: dotted-quad IPv4 literal; fix: bind = \"127.0.0.1\"",
        ),
    )
    lit = try
        parse_bind_ipv4_literal(raw)
    catch e
        e isa ArgumentError || rethrow()
        throw(ArgumentError(replace(e.msg, r"^bind " => "$ctx: bind ")))
    end
    return lit.canonical
end

function bind_dry_run_display(lit::BindIPv4Literal)::String
    lit.all_interfaces && return "0.0.0.0 (all interfaces)"
    return lit.canonical
end

function _loopback_bind_lit(lit::BindIPv4Literal)::Bool
    return lit.loopback
end

public BindIPv4Literal, bind_dry_run_display, parse_bind_ipv4_literal, read_toml_bind_string
