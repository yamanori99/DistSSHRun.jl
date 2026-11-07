# Structured host facts. CLI formatting lives in DistSSHRun.

"""One requested host. Missing fields are `nothing`, never `0` or `0.0`.

`reachable` is false when SSH (or the local probe) failed as a whole.
A reachable host may still omit fields. Julia executable/version is optional:
absence is a missing field, not a host failure.
`julia_version` is the `julia --version` text (not a `VersionNumber`; it does
not promise a commit).
"""
struct HostFacts
    selector::String
    identity::String
    reachable::Bool
    error::Union{Nothing, String}
    total_memory_bytes::Union{Nothing, UInt64}
    ncpu::Union{Nothing, Int}
    os::Union{Nothing, String}
    julia_exe::Union{Nothing, String}
    julia_version::Union{Nothing, String}
end

# Labeled lines so a missing RAM/CPU/OS command cannot shift later fields.
# awk uses printf "%.0f" so MemTotal*1024 stays decimal; the parser still
# accepts scientific notation if a remote awk uses default OFMT.
const _HOSTINFO_PROBE_SCRIPT = string(
    "echo DISTSSHKIT_HOSTINFO; ",
    "echo mem=\$(sysctl -n hw.memsize 2>/dev/null || awk '/MemTotal/{printf \"%.0f\\n\", \$2*1024}' /proc/meminfo 2>/dev/null); ",
    "echo ncpu=\$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null); ",
    "echo os=\$(uname -s 2>/dev/null)",
)

function _hostinfo_parse_u64(s::AbstractString)::Union{Nothing, UInt64}
    t = strip(String(s))
    isempty(t) && return nothing
    n = tryparse(UInt64, t)
    if n !== nothing
        n == 0 && return nothing
        return n
    end
    f = tryparse(Float64, t)
    f === nothing && return nothing
    isfinite(f) || return nothing
    f < 1 && return nothing
    f > Float64(typemax(UInt64)) && return nothing
    r = round(UInt64, f)
    r == 0 && return nothing
    return r
end

function _hostinfo_parse_ncpu(s::AbstractString)::Union{Nothing, Int}
    n = tryparse(Int, strip(String(s)))
    n === nothing && return nothing
    n <= 0 && return nothing
    return n
end

function _hostinfo_parse_os(s::AbstractString)::Union{Nothing, String}
    t = strip(String(s))
    return isempty(t) ? nothing : t
end

function _hostinfo_labeled_value(
        lines::AbstractVector{<:AbstractString},
        key::AbstractString,
    )::Union{Nothing, String}
    prefix = String(key) * "="
    for l in lines
        startswith(l, prefix) || continue
        return String(SubString(l, ncodeunits(prefix) + 1))
    end
    return nothing
end

function _hostinfo_parse_probe(
        out::AbstractString,
    )::Union{Nothing, NamedTuple{(:total_memory_bytes, :ncpu, :os), Tuple{Union{Nothing, UInt64}, Union{Nothing, Int}, Union{Nothing, String}}}}
    lines = String[strip(l) for l in split(String(out), '\n') if !isempty(strip(l))]
    i = findfirst(==("DISTSSHKIT_HOSTINFO"), lines)
    i === nothing && return nothing
    rest = lines[(i + 1):end]
    mem_raw = _hostinfo_labeled_value(rest, "mem")
    ncpu_raw = _hostinfo_labeled_value(rest, "ncpu")
    os_raw = _hostinfo_labeled_value(rest, "os")
    return (
        total_memory_bytes = mem_raw === nothing ? nothing : _hostinfo_parse_u64(mem_raw),
        ncpu = ncpu_raw === nothing ? nothing : _hostinfo_parse_ncpu(ncpu_raw),
        os = os_raw === nothing ? nothing : _hostinfo_parse_os(os_raw),
    )
end

function _local_ncpu()::Union{Nothing, Int}
    n = try
        s = strip(read(pipeline(`sysctl -n hw.ncpu`, stderr = devnull), String))
        isempty(s) ? Sys.CPU_THREADS : parse(Int, s)
    catch
        Sys.CPU_THREADS
    end
    n isa Integer || return nothing
    n <= 0 && return nothing
    return Int(n)
end

function _local_julia_exe()::Union{Nothing, String}
    p = joinpath(Sys.BINDIR, Base.julia_exename())
    return isfile(p) ? p : nothing
end

function _julia_version_text(exe::AbstractString)::Union{Nothing, String}
    try
        t = strip(read(`$(String(exe)) --version`, String))
        return isempty(t) ? nothing : t
    catch
        return nothing
    end
end

function _attach_local_julia(facts::HostFacts)::HostFacts
    exe = facts.julia_exe === nothing ? _local_julia_exe() : facts.julia_exe
    ver = exe === nothing ? nothing : _julia_version_text(exe)
    return HostFacts(
        facts.selector,
        facts.identity,
        facts.reachable,
        facts.error,
        facts.total_memory_bytes,
        facts.ncpu,
        facts.os,
        exe,
        ver,
    )
end

function _attach_remote_julia(
        facts::HostFacts;
        julia::Union{Nothing, AbstractString},
    )::HostFacts
    facts.reachable || return facts
    exe = try
        resolve_remote_julia(facts.identity, julia)
    catch
        nothing
    end
    exe === nothing && return facts
    ver = try
        t = strip(_remote_julia_version_output(facts.identity, exe))
        isempty(t) ? nothing : t
    catch
        nothing
    end
    return HostFacts(
        facts.selector,
        facts.identity,
        facts.reachable,
        facts.error,
        facts.total_memory_bytes,
        facts.ncpu,
        facts.os,
        exe,
        ver,
    )
end

function _collect_local_host_facts(selector::AbstractString, identity::AbstractString)::HostFacts
    mem = let m = Sys.total_memory()
        m == 0 ? nothing : UInt64(m)
    end
    os = let k = strip(string(Sys.KERNEL))
        isempty(k) ? nothing : k
    end
    facts = HostFacts(
        String(selector),
        String(identity),
        true,
        nothing,
        mem,
        _local_ncpu(),
        os,
        nothing,
        nothing,
    )
    return _attach_local_julia(facts)
end

function _collect_remote_host_facts(
        selector::AbstractString,
        identity::AbstractString;
        julia::Union{Nothing, AbstractString},
    )::HostFacts
    h = String(identity)
    try
        raw = read(
            pipeline(_host_sync_remote_shell_cmd(h, _HOSTINFO_PROBE_SCRIPT); stderr = devnull),
            String,
        )
        parsed = _hostinfo_parse_probe(raw)
        if parsed === nothing
            return HostFacts(
                String(selector), h, false, "resource probe failed",
                nothing, nothing, nothing, nothing, nothing,
            )
        end
        facts = HostFacts(
            String(selector),
            h,
            true,
            nothing,
            parsed.total_memory_bytes,
            parsed.ncpu,
            parsed.os,
            nothing,
            nothing,
        )
        return _attach_remote_julia(facts; julia = julia)
    catch e
        _rethrow_missing_host_tool(e)
        return HostFacts(
            String(selector),
            h,
            false,
            sprint(showerror, e),
            nothing, nothing, nothing, nothing, nothing,
        )
    end
end

"""Collect facts for one host (`parent` is local). Does not start jobs."""
function collect_host_facts(
        identity::AbstractString;
        selector::AbstractString = identity,
        julia::Union{Nothing, AbstractString} = nothing,
    )::HostFacts
    id = String(identity)
    sel = String(selector)
    if is_parent_host_name(id)
        return _collect_local_host_facts(sel, PARENT_HOST_NAME)
    end
    return _collect_remote_host_facts(sel, id; julia = julia)
end

"""Collect facts for each requested identity. One row per name, in order."""
function collect_host_facts(
        hosts::AbstractVector{<:AbstractString};
        julia::Union{Nothing, AbstractString} = nothing,
    )::Vector{HostFacts}
    out = HostFacts[]
    for h in hosts
        push!(out, collect_host_facts(h; julia = julia))
    end
    return out
end
