struct ProcessRow
    pid::Int
    ppid::Int
    etime::String
    command::String
end

function _env_pair_matches(
        pair::AbstractString,
        key::AbstractString,
        value::AbstractString;
        prefix::Bool,
    )::Bool
    prefix_key = string(key, "=")
    startswith(pair, prefix_key) || return false
    val = pair[(length(prefix_key) + 1):end]
    return prefix ? startswith(val, value) : val == value
end

function _environ_has_mark(
        data::AbstractVector{UInt8},
        key::AbstractString,
        value::AbstractString;
        prefix::Bool,
    )::Bool
    start = 1
    n = length(data)
    while start <= n
        z = findnext(==(UInt8(0)), data, start)
        z === nothing && (z = n + 1)
        segment = String(@view data[start:(z - 1)])
        _env_pair_matches(segment, key, value; prefix) && return true
        start = z + 1
    end
    return false
end

function _read_proc_etime(pid::Int)::String
    try
        out = strip(String(read(`ps -p $pid -o etime=`)))
        return isempty(out) ? "" : out
    catch
        return ""
    end
end

function _command_from_proc(pid::Int)::String
    cmd = "/proc/$pid/cmdline"
    isfile(cmd) || return ""
    raw = read(cmd)
    parts = String[]
    start = 1
    n = length(raw)
    for i in 1:n
        raw[i] == 0x00 && continue
        if i == 1 || raw[i - 1] == 0x00
            start = i
        end
        if i == n || raw[i + 1] == 0x00
            push!(parts, String(@view raw[start:i]))
        end
    end
    return join(parts, " ")
end

function _ppid_from_proc(pid::Int)::Int
    stat = "/proc/$pid/stat"
    isfile(stat) || return 0
    line = read(stat, String)
    j = findfirst(')', line)
    j === nothing && return 0
    rest = strip(line[(j + 1):end])
    flds = split(rest)
    length(flds) < 2 && return 0
    return something(tryparse(Int, flds[2]), 0)
end

function _processes_with_env_proc(
        key::AbstractString,
        value::AbstractString;
        prefix::Bool = false,
        exclude::AbstractSet{<:Integer} = Set{Int}(),
    )
    rows = ProcessRow[]
    for name in readdir("/proc")
        pid = tryparse(Int, name)
        pid === nothing && continue
        Int(pid) in exclude && continue
        envp = "/proc/$pid/environ"
        isfile(envp) || continue
        data = try
            read(envp)
        catch
            continue
        end
        _environ_has_mark(data, key, value; prefix) || continue
        push!(
            rows,
            ProcessRow(
                Int(pid),
                _ppid_from_proc(Int(pid)),
                _read_proc_etime(Int(pid)),
                _command_from_proc(Int(pid)),
            ),
        )
    end
    return rows
end

function _argv_before_env(cmd::AbstractString)::String
    parts = split(cmd)
    cut = findfirst(parts) do part
        !startswith(part, "-") && occursin(r"^[A-Za-z_][A-Za-z0-9_]*=", part)
    end
    cut === nothing && return cmd
    cut == 1 && return cmd
    return join(parts[1:(cut - 1)], " ")
end

function _ps_line_has_mark(
        line::AbstractString,
        key::AbstractString,
        value::AbstractString;
        prefix::Bool,
    )::Bool
    needle = string(key, "=", value)
    searchfrom = 1
    while true
        idx = findnext(needle, line, searchfrom)
        idx === nothing && return false
        at = first(idx)
        before_ok = at == 1 || isspace(line[prevind(line, at)])
        after = nextind(line, last(idx))
        after_ok = prefix || after > ncodeunits(line) || isspace(line[after])
        before_ok && after_ok && return true
        searchfrom = nextind(line, at)
    end
    return
end

function _processes_with_env_ps(
        key::AbstractString,
        value::AbstractString;
        prefix::Bool = false,
        exclude::AbstractSet{<:Integer} = Set{Int}(),
    )
    rows = ProcessRow[]
    out = try
        String(read(`ps -E -ww -A -o pid=,ppid=,etime=,command=`))
    catch
        return rows
    end
    for line in eachline(IOBuffer(out); keep = true)
        isempty(strip(line)) && continue
        m = match(r"^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$", line)
        m === nothing && continue
        pid = parse(Int, m.captures[1])
        pid in exclude && continue
        _ps_line_has_mark(line, key, value; prefix) || continue
        cmd = _argv_before_env(String(m.captures[4]))
        # `ps -E` inherits the caller's environment and would match itself.
        startswith(lstrip(cmd), "ps ") && continue
        push!(
            rows,
            ProcessRow(
                pid,
                parse(Int, m.captures[2]),
                String(m.captures[3]),
                cmd,
            ),
        )
    end
    return rows
end

"""
    processes_with_env(key, value; prefix=false, exclude=(getpid(),))

Return processes whose environment contains `key=value`, or when `prefix` is
true, a `key` whose value starts with `value`. Excluded pids are omitted.
macOS uses `ps -E`; Linux reads `/proc/*/environ`.
"""
function processes_with_env(
        key::AbstractString,
        value::AbstractString;
        prefix::Bool = false,
        exclude = nothing,
    )
    exc = if exclude === nothing
        Set{Int}((Int(getpid()),))
    else
        Set{Int}(Int(p) for p in exclude)
    end
    if Sys.islinux()
        return _processes_with_env_proc(key, value; prefix = prefix, exclude = exc)
    elseif Sys.isapple()
        return _processes_with_env_ps(key, value; prefix = prefix, exclude = exc)
    else
        return ProcessRow[]
    end
end
