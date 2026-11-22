# Host-aware exclusive `.distssh.lock`. A malformed record is never taken or pruned.

const _OUTPUT_LOCK_NAME = ".distssh.lock"
const _OUTPUT_LOCK_TRIES = 8

"""Hostname recorded in `.distssh.lock`. Empty output is an error."""
function _output_lock_host()::String
    host = try
        strip(read(`hostname`, String))
    catch
        ""
    end
    (isempty(host) || occursin('\n', host) || occursin('\r', host)) &&
        throw(ArgumentError("output lock: hostname is empty or has a line break"))
    return host
end

"""Hex start key for `pid`, or `nothing` when the key cannot be read."""
function _output_lock_start_hex(pid::Integer)::Union{Nothing, String}
    key = kit_process_start_key(pid)
    key === nothing && return nothing
    isempty(key) && return nothing
    return bytes2hex(codeunits(String(key)))
end

function _output_lock_writer()::String
    return DistSSHBase.record_writer_string("DistSSHRun", dist_ssh_kit_version())
end

function _output_lock_text(host::AbstractString, pid::Integer, start_hex::AbstractString, id::AbstractString)::String
    for (label, value) in (
            ("host", String(host)),
            ("start", String(start_hex)),
            ("id", String(id)),
            ("writer", _output_lock_writer()),
        )
        if occursin('\n', value) || occursin('\r', value) || occursin('=', value) && label != "writer"
            throw(ArgumentError("output lock: $(label) contains a reserved character"))
        end
    end
    return string(
        "writer=", _output_lock_writer(), "\n",
        "host=", String(host), "\n",
        "pid=", Int(pid), "\n",
        "start=", String(start_hex), "\n",
        "id=", String(id), "\n",
    )
end

function _parse_output_lock(text::AbstractString)
    fields = Dict{String, String}()
    for raw in split(String(text), '\n'; keepempty = false)
        line = String(raw)
        i = findfirst(==('='), line)
        i === nothing && return nothing
        key = line[1:(i - 1)]
        key in ("writer", "host", "pid", "start", "id") || return nothing
        haskey(fields, key) && return nothing
        fields[key] = line[(i + 1):end]
    end
    for key in ("writer", "host", "pid", "start", "id")
        haskey(fields, key) || return nothing
    end
    isempty(fields["host"]) && return nothing
    isempty(fields["start"]) && return nothing
    pid = tryparse(Int, fields["pid"])
    (pid === nothing || pid <= 0) && return nothing
    DistSSHBase.record_writer_minor_match(
        fields["writer"], "DistSSHRun", dist_ssh_kit_version(),
    ) == :ok || return nothing
    return (;
        host = fields["host"],
        pid = pid,
        start = fields["start"],
        id = fields["id"],
    )
end

"""`true` when the record must not be removed: foreign host, or same host and still this process."""
function _output_lock_blocks(rec, host::AbstractString)::Bool
    String(rec.host) != String(host) && return true
    kit_pid_alive(rec.pid) || return false
    current = _output_lock_start_hex(rec.pid)
    current === nothing && return true
    return current == String(rec.start)
end

function _excl_write_lock(path::AbstractString, body::AbstractString)::Bool
    tmp = string(path, ".", getpid(), ".", time_ns(), ".tmp")
    open(tmp, "w") do io
        write(io, body)
    end
    rc = ccall(:link, Cint, (Cstring, Cstring), tmp, path)
    rm(tmp; force = true)
    return rc == 0
end

"""
    output_dir_lock!(output_dir; id=nothing) -> release::Function

Exclusive `.distssh.lock` in `output_dir`. The record stores writer, host, pid,
start key, and an optional job id. A live same-host owner or a foreign host
throws. A dead same-host owner, or the same pid with a different start key,
is replaced. The release removes the file only when host, pid, and start key
still match.
"""
function output_dir_lock!(
        output_dir::AbstractString;
        id::Union{Nothing, AbstractString} = nothing,
    )
    mkpath(output_dir)
    lock_path = joinpath(output_dir, _OUTPUT_LOCK_NAME)
    host = _output_lock_host()
    mypid = getpid()
    start = _output_lock_start_hex(mypid)
    start === nothing &&
        throw(ArgumentError("output lock: process start key is unreadable"))
    id_s = if id === nothing || isempty(strip(String(id)))
        ""
    else
        _parse_kit_job_id(String(id))
    end
    body = _output_lock_text(host, mypid, start, id_s)
    release = () -> begin
        try
            isfile(lock_path) || return nothing
            rec = _parse_output_lock(read(lock_path, String))
            rec === nothing && return nothing
            (rec.host == host && rec.pid == mypid && rec.start == start) || return nothing
            rm(lock_path; force = true)
        catch
        end
        return nothing
    end
    for _ in 1:_OUTPUT_LOCK_TRIES
        _excl_write_lock(lock_path, body) && return release
        raw = try
            read(lock_path, String)
        catch
            ""
        end
        rec = _parse_output_lock(raw)
        if rec === nothing
            throw(ArgumentError("output lock: malformed lock $(lock_path)"))
        end
        if rec.host == host && rec.pid == mypid && rec.start == start
            return release
        end
        if _output_lock_blocks(rec, host)
            throw(
                ArgumentError(
                    "another DistSSHRun run (pid $(rec.pid) on $(rec.host)) already holds $(lock_path)",
                ),
            )
        end
        rm(lock_path; force = true)
    end
    throw(ArgumentError("output lock: could not create $(lock_path)"))
end

"""Job id suffix of a `<stem>_<YYYYMMDDTHHMMSSZ>[_<job_id>]` leaf, else `nothing`."""
function _leaf_job_id(name::AbstractString)::Union{Nothing, String}
    m = match(r"^.*_[0-9]{8}T[0-9]{6}Z_(.+)$", String(name))
    m === nothing && return nothing
    job = String(something(m.captures[1], ""))
    try
        return _parse_kit_job_id(job)
    catch
        return nothing
    end
end

"""Reason string when `dir` must not be pruned, else `nothing`."""
function _output_lock_prune_block(dir::AbstractString)::Union{Nothing, String}
    isdir(dir) || return nothing
    host = _output_lock_host()
    locks = String[]
    direct = joinpath(dir, _OUTPUT_LOCK_NAME)
    isfile(direct) && push!(locks, direct)
    for (root, _, files) in walkdir(String(dir))
        _OUTPUT_LOCK_NAME in files || continue
        path = joinpath(root, _OUTPUT_LOCK_NAME)
        path in locks || push!(locks, path)
    end
    for path in locks
        raw = try
            read(path, String)
        catch
            return "refusing to prune live lock $(path)"
        end
        rec = _parse_output_lock(raw)
        rec === nothing && return "refusing to prune live lock $(path)"
        _output_lock_blocks(rec, host) && return "refusing to prune live lock $(path)"
    end
    return nothing
end

"""Shell helpers for `.distssh.lock` liveness. Values are embedded here."""
function _output_lock_shell_helpers()::String
    maj, minr = DistSSHBase.record_writer_minor_parts(dist_ssh_kit_version())
    awk = raw"""
              {
                s = $0
                if (!match(s, /.*)/)) exit 1
                rest = substr(s, RLENGTH + 1)
                sub(/^[[:space:]]+/, "", rest)
                n = split(rest, a, /[[:space:]]+/)
                if (n < 20) exit 1
                printf "%s", a[20]
              }
    """
    return """
    _distssh_start_hex() {
      _pid=\$1
      if [ -r "/proc/\${_pid}/stat" ]; then
        _cur=\$(awk '$awk' "/proc/\${_pid}/stat") || return 1
      else
        _cur=\$(ps -o lstart= -p "\$_pid" 2>/dev/null) || return 1
        _cur=\$(printf '%s' "\$_cur" | sed 's/^[[:space:]]*//;s/[[:space:]]*\$//')
      fi
      [ -n "\$_cur" ] || return 1
      printf '%s' "\$_cur" | od -An -tx1 | tr -d ' \\n'
    }
    _distssh_one_blocks() {
      _f=\$1
      [ -f "\$_f" ] || return 1
      _writer=\$(sed -n 's/^writer=//p' "\$_f" | head -n 1)
      _host=\$(sed -n 's/^host=//p' "\$_f" | head -n 1)
      _pid=\$(sed -n 's/^pid=//p' "\$_f" | head -n 1)
      _start=\$(sed -n 's/^start=//p' "\$_f" | head -n 1)
      _idline=\$(sed -n 's/^id=//p' "\$_f" | head -n 1)
      [ -n "\$_writer" ] && [ -n "\$_host" ] && [ -n "\$_pid" ] && [ -n "\$_start" ] || return 0
      case "\$_writer" in
        "DistSSHRun $(maj).$(minr)"|"DistSSHRun $(maj).$(minr)."*) ;;
        *) return 0 ;;
      esac
      _me=\$(hostname)
      [ "\$_host" = "\$_me" ] || return 0
      _alive=0
      if kill -0 "\$_pid" 2>/dev/null; then _alive=1; fi
      if [ -d "/proc/\$_pid" ]; then _alive=1; fi
      if ps -p "\$_pid" >/dev/null 2>&1; then _alive=1; fi
      [ "\$_alive" = 1 ] || return 1
      _hex=\$(_distssh_start_hex "\$_pid") || return 0
      [ -n "\$_hex" ] || return 0
      [ "\$_hex" = "\$_start" ] && return 0
      return 1
    }
    _distssh_tree_blocks() {
      _root=\$1
      _list=\$(find "\$_root" -name .distssh.lock -type f 2>/dev/null) || return 0
      [ -n "\$_list" ] || return 1
      _any=\$(printf '%s\\n' "\$_list" | while IFS= read -r _f; do
        if _distssh_one_blocks "\$_f"; then
          printf x
          break
        fi
      done)
      [ -n "\$_any" ]
    }
    """
end

"""Shell that writes `.distssh.lock`. Not included in the prune script."""
function _output_lock_hold_shell_helpers()::String
    writer_q = posix_quote(_output_lock_writer())
    return _output_lock_shell_helpers() * """
        _distssh_hold_lock() {
          _dir=\$1
          _id=\$2
          mkdir -p "\$_dir" || exit 1
          _hex=\$(_distssh_start_hex \$\$) || exit 1
          [ -n "\$_hex" ] || exit 1
          _host=\$(hostname)
          _writer=$writer_q
          _tmp=\$(mktemp "\$_dir/.distssh.lock.XXXXXX") || exit 1
          printf '%s\\n' "writer=\${_writer}" "host=\${_host}" "pid=\$\$" "start=\${_hex}" "id=\${_id}" > "\$_tmp" || {
            rm -f "\$_tmp"
            exit 1
          }
          if ln "\$_tmp" "\$_dir/.distssh.lock" 2>/dev/null; then
            rm -f "\$_tmp"
            return 0
          fi
          rm -f "\$_tmp"
          [ -f "\$_dir/.distssh.lock" ] || exit 1
          return 0
        }
        """
end

"""Statement that writes `.distssh.lock` in a remote directory word. `id` may be empty."""
function output_lock_hold_shell(dir_word::AbstractString, id::AbstractString = "")::String
    id_s = isempty(strip(String(id))) ? "" : _parse_kit_job_id(String(id))
    return "_distssh_hold_lock $(dir_word) $(posix_quote(id_s))"
end
