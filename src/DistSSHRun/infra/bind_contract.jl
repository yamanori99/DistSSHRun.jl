# Strict Distributed bind literals (#503). Does not use `parse(IPv4)`.

"""Parsed canonical IPv4 bind literal for launch."""
struct BindIPv4Literal
    canonical::String
    loopback::Bool
    all_interfaces::Bool
end

const _BIND_FIX_LOOPBACK = "bind = \"127.0.0.1\""
const _BIND_CHECK_IPV4 = "dotted-quad IPv4 literal"
const _BIND_CHECK_IPV4_NAMES = "dotted-quad IPv4 literal (names are not resolved)"
const _BIND_CHECK_UNICAST = "dotted-quad IPv4 unicast literal"

function _bind_ipv4_error(raw::AbstractString, checked::AbstractString)
    return ArgumentError("bind $(repr(raw)) is not an IPv4 address; checked: $checked; fix: $_BIND_FIX_LOOPBACK")
end

function _bind_other_error(raw::AbstractString, what::AbstractString, checked::AbstractString)
    return ArgumentError("bind $(repr(raw)) $what; checked: $checked; fix: $_BIND_FIX_LOOPBACK")
end

function _reject_bind_whitespace(raw::AbstractString)
    s = String(raw)
    if s != strip(s)
        throw(
            ArgumentError(
                "bind $(repr(raw)) must not contain leading or trailing whitespace; checked: $_BIND_CHECK_IPV4; fix: $_BIND_FIX_LOOPBACK",
            ),
        )
    end
    for c in s
        isspace(c) && throw(
            ArgumentError(
                "bind $(repr(raw)) must not contain whitespace; checked: $_BIND_CHECK_IPV4; fix: $_BIND_FIX_LOOPBACK",
            ),
        )
    end
    return s
end

function _looks_like_ipv4_port(s::AbstractString)
    m = match(r"^(\d{1,3})(\.\d{1,3}){3}:\d+", s)
    return m !== nothing
end

function _reject_non_ipv4_bind_shape(raw::AbstractString)
    s = _reject_bind_whitespace(raw)
    isempty(s) &&
        throw(ArgumentError("bind is empty; checked: $_BIND_CHECK_IPV4; fix: $_BIND_FIX_LOOPBACK"))
    if _looks_like_ipv4_port(s)
        throw(_bind_ipv4_error(raw, "$_BIND_CHECK_IPV4 (ports are not allowed)"))
    end
    if occursin('%', s)
        throw(_bind_ipv4_error(raw, "$_BIND_CHECK_IPV4 (IPv6 and zone IDs are not supported)"))
    end
    if occursin(':', s) || occursin('[', s) || occursin(']', s)
        throw(_bind_ipv4_error(raw, "$_BIND_CHECK_IPV4 (IPv6 is not supported)"))
    end
    if occursin('/', s)
        throw(_bind_ipv4_error(raw, "$_BIND_CHECK_IPV4 (CIDR is not supported)"))
    end
    if !occursin('.', s) && occursin(r"[A-Za-z]", s)
        throw(_bind_ipv4_error(raw, _BIND_CHECK_IPV4_NAMES))
    end
    return s
end

function _bind_octet_invalid_reason(part::AbstractString)::Union{Nothing, String}
    isempty(part) && return nothing
    part[1] == '-' && return "must not contain a sign"
    part[1] == '+' && return "must not contain a sign"
    length(part) > 1 && part[1] == '0' && all(c -> '0' <= c <= '9', part) && return "must not use leading zeros"
    if length(part) > 3
        all(c -> '0' <= c <= '9', part) && return "exceeds 255"
    end
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

function _classify_bind_octets(o1::Int, o2::Int, o3::Int, o4::Int)
    all_interfaces = o1 == 0 && o2 == 0 && o3 == 0 && o4 == 0
    loopback = o1 == 127
    multicast = 224 <= o1 <= 239
    zero_subnet = o1 == 0 && !all_interfaces
    reserved = (240 <= o1 <= 254) || (o1 == 255 && !(o1 == 255 && o2 == 255 && o3 == 255 && o4 == 255))
    broadcast = o1 == 255 && o2 == 255 && o3 == 255 && o4 == 255
    return (all_interfaces, loopback, multicast, zero_subnet, reserved, broadcast)
end

"""
    parse_bind_ipv4_literal(raw::AbstractString) -> BindIPv4Literal

Accept only canonical dotted-quad IPv4 (decimal, 0-255, no leading zeros, no
signs, exactly four parts). Rejects host names, ports, IPv6, and whitespace.
"""
function parse_bind_ipv4_literal(raw::AbstractString)::BindIPv4Literal
    s = _reject_non_ipv4_bind_shape(raw)
    parts = split(s, '.')
    if length(parts) != 4
        occursin(r"[A-Za-z]", s) && throw(_bind_ipv4_error(raw, _BIND_CHECK_IPV4_NAMES))
        throw(_bind_ipv4_error(raw, "$_BIND_CHECK_IPV4 (need four decimal parts)"))
    end
    octets = Int[]
    for part in parts
        if isempty(part)
            throw(_bind_ipv4_error(raw, "$_BIND_CHECK_IPV4 (need four decimal parts)"))
        end
        if part[1] == '-' || part[1] == '+'
            throw(_bind_ipv4_error(raw, "$_BIND_CHECK_IPV4 (must not contain a sign)"))
        end
        if !all(c -> '0' <= c <= '9', part)
            if all(c -> ('0' <= c <= '9') || ('a' <= lowercase(c) <= 'z'), part) &&
                    all(c -> ('a' <= lowercase(c) <= 'z'), part)
                throw(_bind_ipv4_error(raw, _BIND_CHECK_IPV4_NAMES))
            end
            throw(_bind_ipv4_error(raw, "$_BIND_CHECK_IPV4 (must use decimal digits only)"))
        end
        why = _bind_octet_invalid_reason(part)
        why !== nothing && throw(_bind_ipv4_error(raw, "$_BIND_CHECK_IPV4 ($why)"))
        push!(octets, parse(Int, part; base = 10))
    end
    o1, o2, o3, o4 = octets
    all_if, loopback, multicast, zero_subnet, reserved, broadcast =
        _classify_bind_octets(o1, o2, o3, o4)
    broadcast && throw(_bind_other_error(raw, "is a broadcast address", _BIND_CHECK_UNICAST))
    multicast && throw(_bind_other_error(raw, "is a multicast address", _BIND_CHECK_UNICAST))
    zero_subnet && throw(_bind_other_error(raw, "is in 0.0.0.0/8", _BIND_CHECK_UNICAST))
    reserved && throw(_bind_other_error(raw, "is a reserved address", _BIND_CHECK_UNICAST))
    canonical = join(string.(octets), '.')
    return BindIPv4Literal(canonical, loopback, all_if)
end

function bind_dry_run_display(lit::BindIPv4Literal)::String
    lit.all_interfaces && return "0.0.0.0 (all interfaces)"
    return lit.canonical
end

public BindIPv4Literal, bind_dry_run_display, parse_bind_ipv4_literal
