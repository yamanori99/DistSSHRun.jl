# Structured host facts and labeled print layout. The hostinfo CLI stays in DistSSHRun.

"""One requested host. Missing fields are `nothing`, never `0` or `0.0`.

`reachable` is false when SSH (or the local probe) failed as a whole.
A reachable host may still omit fields. Julia executable/version is optional:
absence is a missing field, not a host failure.
`julia_version` is the `julia --version` text (not a `VersionNumber`; it does
not promise a commit).

`os` is the kernel family from `uname -s` (for example `Darwin` or `Linux`).
`os_version` is a product/release id when available (`sw_vers -productVersion`
or `/etc/os-release` `VERSION_ID`), never a kernel release.
`os_pretty` is a product display name when available (`sw_vers -productName` or
`PRETTY_NAME`). `kernel_release` is `uname -r`. Do not treat `os_version` as
`kernel_release`.
`arch` is `uname -m`. `cpu_model` is best-effort brand/model text.
"""
struct HostFacts
    selector::String
    identity::String
    reachable::Bool
    error::Union{Nothing, String}
    total_memory_bytes::Union{Nothing, UInt64}
    ncpu::Union{Nothing, Int}
    os::Union{Nothing, String}
    os_version::Union{Nothing, String}
    os_pretty::Union{Nothing, String}
    kernel_release::Union{Nothing, String}
    arch::Union{Nothing, String}
    cpu_model::Union{Nothing, String}
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
    "echo os=\$(uname -s 2>/dev/null); ",
    "echo kernel=\$(uname -r 2>/dev/null); ",
    "echo arch=\$(uname -m 2>/dev/null); ",
    "echo os_version=\$(sw_vers -productVersion 2>/dev/null || awk -F= '/^VERSION_ID=/{gsub(/\"/,\"\",\$2); print \$2; exit}' /etc/os-release 2>/dev/null); ",
    "echo os_pretty=\$(sw_vers -productName 2>/dev/null || awk -F= '/^PRETTY_NAME=/{gsub(/\"/,\"\",\$2); print \$2; exit}' /etc/os-release 2>/dev/null); ",
    "echo cpu_model=\$(sysctl -n machdep.cpu.brand_string 2>/dev/null || awk -F': ' '/^[Mm]odel name/{print \$2; exit}' /proc/cpuinfo 2>/dev/null || awk -F': ' '/^Hardware/{print \$2; exit}' /proc/cpuinfo 2>/dev/null)",
)

const _HOSTINFO_PROBE_KEYS = (
    :total_memory_bytes,
    :ncpu,
    :os,
    :os_version,
    :os_pretty,
    :kernel_release,
    :arch,
    :cpu_model,
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

function _hostinfo_parse_text(s::AbstractString)::Union{Nothing, String}
    t = strip(String(s))
    return isempty(t) ? nothing : t
end

const _hostinfo_parse_os = _hostinfo_parse_text

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
    )::Union{
        Nothing, NamedTuple{
            _HOSTINFO_PROBE_KEYS, Tuple{
                Union{Nothing, UInt64},
                Union{Nothing, Int},
                Union{Nothing, String},
                Union{Nothing, String},
                Union{Nothing, String},
                Union{Nothing, String},
                Union{Nothing, String},
                Union{Nothing, String},
            },
        },
    }
    lines = String[strip(l) for l in split(String(out), '\n') if !isempty(strip(l))]
    i = findfirst(==("DISTSSHKIT_HOSTINFO"), lines)
    i === nothing && return nothing
    rest = lines[(i + 1):end]
    mem_raw = _hostinfo_labeled_value(rest, "mem")
    ncpu_raw = _hostinfo_labeled_value(rest, "ncpu")
    os_raw = _hostinfo_labeled_value(rest, "os")
    os_version_raw = _hostinfo_labeled_value(rest, "os_version")
    os_pretty_raw = _hostinfo_labeled_value(rest, "os_pretty")
    kernel_raw = _hostinfo_labeled_value(rest, "kernel")
    arch_raw = _hostinfo_labeled_value(rest, "arch")
    cpu_model_raw = _hostinfo_labeled_value(rest, "cpu_model")
    return (
        total_memory_bytes = mem_raw === nothing ? nothing : _hostinfo_parse_u64(mem_raw),
        ncpu = ncpu_raw === nothing ? nothing : _hostinfo_parse_ncpu(ncpu_raw),
        os = os_raw === nothing ? nothing : _hostinfo_parse_text(os_raw),
        os_version = os_version_raw === nothing ? nothing : _hostinfo_parse_text(os_version_raw),
        os_pretty = os_pretty_raw === nothing ? nothing : _hostinfo_parse_text(os_pretty_raw),
        kernel_release = kernel_raw === nothing ? nothing : _hostinfo_parse_text(kernel_raw),
        arch = arch_raw === nothing ? nothing : _hostinfo_parse_text(arch_raw),
        cpu_model = cpu_model_raw === nothing ? nothing : _hostinfo_parse_text(cpu_model_raw),
    )
end

function _hostfacts(;
        selector::AbstractString,
        identity::AbstractString,
        reachable::Bool,
        error::Union{Nothing, AbstractString} = nothing,
        total_memory_bytes::Union{Nothing, UInt64} = nothing,
        ncpu::Union{Nothing, Int} = nothing,
        os::Union{Nothing, AbstractString} = nothing,
        os_version::Union{Nothing, AbstractString} = nothing,
        os_pretty::Union{Nothing, AbstractString} = nothing,
        kernel_release::Union{Nothing, AbstractString} = nothing,
        arch::Union{Nothing, AbstractString} = nothing,
        cpu_model::Union{Nothing, AbstractString} = nothing,
        julia_exe::Union{Nothing, AbstractString} = nothing,
        julia_version::Union{Nothing, AbstractString} = nothing,
    )::HostFacts
    return HostFacts(
        String(selector),
        String(identity),
        reachable,
        error === nothing ? nothing : String(error),
        total_memory_bytes,
        ncpu,
        os === nothing ? nothing : String(os),
        os_version === nothing ? nothing : String(os_version),
        os_pretty === nothing ? nothing : String(os_pretty),
        kernel_release === nothing ? nothing : String(kernel_release),
        arch === nothing ? nothing : String(arch),
        cpu_model === nothing ? nothing : String(cpu_model),
        julia_exe === nothing ? nothing : String(julia_exe),
        julia_version === nothing ? nothing : String(julia_version),
    )
end

function _hostfacts_replace(
        facts::HostFacts;
        selector = facts.selector,
        identity = facts.identity,
        reachable = facts.reachable,
        error = facts.error,
        total_memory_bytes = facts.total_memory_bytes,
        ncpu = facts.ncpu,
        os = facts.os,
        os_version = facts.os_version,
        os_pretty = facts.os_pretty,
        kernel_release = facts.kernel_release,
        arch = facts.arch,
        cpu_model = facts.cpu_model,
        julia_exe = facts.julia_exe,
        julia_version = facts.julia_version,
    )::HostFacts
    return _hostfacts(;
        selector = selector,
        identity = identity,
        reachable = reachable,
        error = error,
        total_memory_bytes = total_memory_bytes,
        ncpu = ncpu,
        os = os,
        os_version = os_version,
        os_pretty = os_pretty,
        kernel_release = kernel_release,
        arch = arch,
        cpu_model = cpu_model,
        julia_exe = julia_exe,
        julia_version = julia_version,
    )
end

function _read_cmd_text(cmd::Cmd)::Union{Nothing, String}
    try
        t = strip(read(pipeline(cmd; stderr = devnull), String))
        return isempty(t) ? nothing : t
    catch
        return nothing
    end
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

function _local_os_version()::Union{Nothing, String}
    v = _read_cmd_text(`sw_vers -productVersion`)
    v !== nothing && return v
    try
        for line in eachline("/etc/os-release")
            startswith(line, "VERSION_ID=") || continue
            raw = String(SubString(line, ncodeunits("VERSION_ID=") + 1))
            return _hostinfo_parse_text(replace(raw, "\"" => ""))
        end
    catch
    end
    return nothing
end

function _local_os_pretty()::Union{Nothing, String}
    v = _read_cmd_text(`sw_vers -productName`)
    v !== nothing && return v
    try
        for line in eachline("/etc/os-release")
            startswith(line, "PRETTY_NAME=") || continue
            raw = String(SubString(line, ncodeunits("PRETTY_NAME=") + 1))
            return _hostinfo_parse_text(replace(raw, "\"" => ""))
        end
    catch
    end
    return nothing
end

function _local_cpu_model()::Union{Nothing, String}
    v = _read_cmd_text(`sysctl -n machdep.cpu.brand_string`)
    v !== nothing && return v
    try
        for line in eachline("/proc/cpuinfo")
            if startswith(line, "model name") || startswith(line, "Model name")
                i = findfirst(':', line)
                i === nothing && continue
                return _hostinfo_parse_text(SubString(line, nextind(line, i)))
            elseif startswith(line, "Hardware")
                i = findfirst(':', line)
                i === nothing && continue
                return _hostinfo_parse_text(SubString(line, nextind(line, i)))
            end
        end
    catch
    end
    return nothing
end

function _attach_local_julia(facts::HostFacts)::HostFacts
    exe = facts.julia_exe === nothing ? _local_julia_exe() : facts.julia_exe
    ver = exe === nothing ? nothing : _julia_version_text(exe)
    return _hostfacts_replace(facts; julia_exe = exe, julia_version = ver)
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
    return _hostfacts_replace(facts; julia_exe = exe, julia_version = ver)
end

function _collect_local_host_facts(selector::AbstractString, identity::AbstractString)::HostFacts
    mem = let m = Sys.total_memory()
        m == 0 ? nothing : UInt64(m)
    end
    os = let k = strip(string(Sys.KERNEL))
        isempty(k) ? nothing : k
    end
    facts = _hostfacts(;
        selector = selector,
        identity = identity,
        reachable = true,
        total_memory_bytes = mem,
        ncpu = _local_ncpu(),
        os = os,
        os_version = _local_os_version(),
        os_pretty = _local_os_pretty(),
        kernel_release = _read_cmd_text(`uname -r`),
        arch = _read_cmd_text(`uname -m`),
        cpu_model = _local_cpu_model(),
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
            return _hostfacts(;
                selector = selector,
                identity = h,
                reachable = false,
                error = "resource probe failed",
            )
        end
        facts = _hostfacts(;
            selector = selector,
            identity = h,
            reachable = true,
            total_memory_bytes = parsed.total_memory_bytes,
            ncpu = parsed.ncpu,
            os = parsed.os,
            os_version = parsed.os_version,
            os_pretty = parsed.os_pretty,
            kernel_release = parsed.kernel_release,
            arch = parsed.arch,
            cpu_model = parsed.cpu_model,
        )
        return _attach_remote_julia(facts; julia = julia)
    catch e
        _rethrow_missing_host_tool(e)
        return _hostfacts(;
            selector = selector,
            identity = h,
            reachable = false,
            error = sprint(showerror, e),
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

# Labeled stdout layout for HostFacts (CLI chrome stays in DistSSHRun).

function _hostinfo_dash(x)::String
    x === nothing && return "-"
    return string(x)
end

function _hostinfo_gb(bytes::Union{Nothing, UInt64})::String
    bytes === nothing && return "-"
    return string(round(Float64(bytes) / 1024^3; digits = 1), " GB")
end

function _hostinfo_term_width(io::IO)::Int
    try
        w = displaysize(io)[2]
        w isa Integer && w >= 40 && return Int(w)
    catch
    end
    return OUTPUT_WIDTH
end

function _hostinfo_is_wsl(kernel_release::Union{Nothing, AbstractString})::Bool
    kernel_release === nothing && return false
    k = lowercase(String(kernel_release))
    return occursin("microsoft", k) || occursin("wsl", k)
end

"""Format OS product text without mixing in the kernel release."""
function _hostinfo_os_product(row::HostFacts)::String
    pretty = row.os_pretty
    ver = row.os_version
    os = row.os
    product = if pretty !== nothing && ver !== nothing &&
            (os === nothing || lowercase(os) == "darwin" || !occursin(ver, pretty))
        # Darwin sw_vers: productName + productVersion. Linux PRETTY_NAME often
        # already includes the version; keep it alone when it already mentions it.
        if os !== nothing && lowercase(os) == "darwin"
            string(pretty, " ", ver)
        elseif occursin(ver, pretty)
            pretty
        else
            string(pretty, " ", ver)
        end
    elseif pretty !== nothing
        pretty
    elseif os !== nothing && lowercase(os) == "darwin" && ver !== nothing
        string("macOS ", ver)
    elseif os !== nothing && ver !== nothing
        string(os, " ", ver)
    else
        _hostinfo_dash(os)
    end
    if _hostinfo_is_wsl(row.kernel_release) && !occursin("WSL", product)
        return product == "-" ? "Linux (WSL)" : string(product, " (WSL)")
    end
    return product
end

function _hostinfo_kernel_line(row::HostFacts)::String
    os = row.os
    rel = row.kernel_release
    if os === nothing && rel === nothing
        return "-"
    elseif os === nothing
        return something(rel)
    elseif rel === nothing
        return something(os)
    end
    return string(os, " ", rel)
end

function _hostinfo_cpu_line(row::HostFacts)::String
    arch = row.arch
    ncpu = row.ncpu
    if arch === nothing && ncpu === nothing
        return "-"
    elseif arch === nothing
        return string(something(ncpu), " cores")
    elseif ncpu === nothing
        return string(something(arch), ", - cores")
    end
    return string(arch, ", ", ncpu, " cores")
end

const _HOSTINFO_LABEL_WIDTH = 11

function _hostinfo_field_prefix(label::AbstractString)::String
    return "  " * rpad(String(label) * ":", _HOSTINFO_LABEL_WIDTH) * " "
end

"""Split `value` into lines that fit `width`, preferring breaks after `/` or spaces."""
function _hostinfo_wrap_chunks(value::AbstractString, width::Int)::Vector{String}
    width < 1 && return String[String(value)]
    out = String[]
    remaining = String(value)
    while !isempty(remaining)
        if textwidth(remaining) <= width
            push!(out, remaining)
            break
        end
        # Find the last preferred break within the first `width` display columns.
        cut = 0
        w = 0
        i = firstindex(remaining)
        last = lastindex(remaining)
        hard = 0
        while i <= last
            c = remaining[i]
            cw = textwidth(c)
            w + cw > width && break
            w += cw
            hard = i
            if c == '/' || isspace(c)
                cut = i
            end
            i = nextind(remaining, i)
        end
        hard == 0 && (hard = firstindex(remaining))
        take_to = cut == 0 ? hard : cut
        push!(out, remaining[1:take_to])
        remaining = remaining[nextind(remaining, take_to):end]
    end
    return out
end

function _hostinfo_wrap_value(io::IO, label::AbstractString, value::AbstractString; width::Int)
    prefix = _hostinfo_field_prefix(label)
    avail = max(16, width - textwidth(prefix))
    if textwidth(value) <= avail
        println(io, prefix, value)
        return nothing
    end
    println(io, rstrip(prefix))
    indent = "    "
    body_w = max(16, width - textwidth(indent))
    for chunk in _hostinfo_wrap_chunks(value, body_w)
        println(io, indent, chunk)
    end
    return nothing
end

function _hostinfo_print_field(
        io::IO,
        label::AbstractString,
        value;
        width::Int,
        skip_if_missing::Bool = false,
    )
    if value === nothing
        skip_if_missing && return nothing
        _hostinfo_wrap_value(io, label, "-"; width = width)
        return nothing
    end
    _hostinfo_wrap_value(io, label, string(value); width = width)
    return nothing
end

"""Print host facts. Always writes `io` (requested results, including `--quiet`)."""
function print_hostinfo(rows::AbstractVector{HostFacts}; io::IO = stdout)
    failed = count(r -> !r.reachable, rows)
    extra = failed == 0 ? "" : "  ($failed host$(failed == 1 ? "" : "s") failed)"
    println(io, "Hostinfo: $(length(rows)) host$(length(rows) == 1 ? "" : "s")$extra")
    width = _hostinfo_term_width(io)
    first = true
    for row in rows
        first || println(io)
        first = false
        shown = is_parent_host_name(row.identity) ? PARENT_HOST_NAME : row.identity
        println(io, shown)
        if !row.reachable
            _hostinfo_print_field(io, "Status", "fail"; width = width)
            _hostinfo_print_field(
                io, "Error", something(row.error, "unreachable"); width = width,
            )
            continue
        end
        _hostinfo_print_field(io, "Status", "ok"; width = width)
        _hostinfo_print_field(io, "Julia", row.julia_version; width = width)
        _hostinfo_print_field(io, "Julia exe", row.julia_exe; width = width)
        _hostinfo_print_field(io, "OS", _hostinfo_os_product(row); width = width)
        _hostinfo_print_field(io, "Kernel", _hostinfo_kernel_line(row); width = width)
        _hostinfo_print_field(io, "CPU", _hostinfo_cpu_line(row); width = width)
        _hostinfo_print_field(
            io, "CPU model", row.cpu_model; width = width, skip_if_missing = true,
        )
        _hostinfo_print_field(io, "Memory", _hostinfo_gb(row.total_memory_bytes); width = width)
        if row.error !== nothing
            _hostinfo_print_field(io, "Note", row.error; width = width)
        end
    end
    return nothing
end
