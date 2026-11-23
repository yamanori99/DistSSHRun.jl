"""Linux `/proc/<pid>/stat` starttime field (clock ticks since boot), or `nothing`."""
function _linux_proc_start_key(pid::Integer)::Union{Nothing, String}
    path = string("/proc/", Int(pid), "/stat")
    isfile(path) || return nothing
    s = try
        read(path, String)
    catch e
        e isa InterruptException && rethrow()
        @debug "process_start_key: /proc starttime unread" pid = Int(pid) exception = (e, catch_backtrace())
        return nothing
    end
    r = findlast(')', s)
    r === nothing && return nothing
    parts = split(SubString(s, Int(r) + 1))
    length(parts) < 20 && return nothing
    key = String(parts[20])
    return isempty(key) ? nothing : key
end

"""
    process_start_key(pid) -> Union{Nothing,String}

Identity of this OS pid's start (Linux `/proc` starttime, else `TZ=UTC LC_ALL=C /bin/ps -o lstart=`).
`nothing` if the pid is gone, unreadable, or Windows.
"""
function process_start_key(pid::Integer)::Union{Nothing, String}
    pid <= 0 && return nothing
    Sys.iswindows() && return nothing
    if isfile(string("/proc/", Int(pid), "/stat"))
        return _linux_proc_start_key(pid)
    end
    isfile("/bin/ps") || return nothing
    try
        s = withenv("TZ" => "UTC", "LC_ALL" => "C") do
            strip(read(`/bin/ps -o lstart= -p $(Int(pid))`, String))
        end
        return isempty(s) ? nothing : s
    catch e
        e isa InterruptException && rethrow()
        @debug "process_start_key: ps lstart unread" pid = Int(pid) exception = (e, catch_backtrace())
        return nothing
    end
end
