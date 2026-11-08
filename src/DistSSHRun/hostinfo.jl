# hostinfo CLI: format DistSSHBase.HostFacts. Collection stays in Base.

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
