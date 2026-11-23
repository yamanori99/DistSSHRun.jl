# Host-aware exclusive `.distssh.lock`. A malformed record is never taken or pruned.

const _OUTPUT_LOCK_NAME = ".distssh.lock"
const _OUTPUT_LOCK_TRIES = 8

"""Hostname recorded in `.distssh.lock`. Same as [`kit_head_host_label`](@ref)."""
function _output_lock_host()::String
    host = kit_head_host_label()
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

function _output_lock_start_hex_ok(start_hex::AbstractString)::Bool
    s = String(start_hex)
    n = ncodeunits(s)
    (n > 0 && iseven(n)) || return false
    return all(c -> ('0' <= c <= '9') || ('a' <= c <= 'f'), s)
end

function _output_lock_text(host::AbstractString, pid::Integer, start_hex::AbstractString, id::AbstractString)::String
    _output_lock_start_hex_ok(start_hex) ||
        throw(ArgumentError("output lock: start is not lowercase hex"))
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
    _output_lock_start_hex_ok(fields["start"]) || return nothing
    for key in ("host", "pid", "start", "id")
        occursin('=', fields[key]) && return nothing
    end
    idv = fields["id"]
    if !isempty(idv) && !occursin(r"^[A-Za-z0-9._:@+-]+$", idv)
        return nothing
    end
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

"""Remove `lock_path` only when it still names the observed inode and bytes."""
function _unlink_output_lock_if_record!(lock_path::AbstractString, expected::AbstractString)::Bool
    isfile(lock_path) || return false
    token = string(lock_path, ".stale.", getpid(), ".", time_ns())
    rc = ccall(:link, Cint, (Cstring, Cstring), lock_path, token)
    rc == 0 || return false
    try
        read(token, String) == String(expected) || return false
        st_tok = stat(token)
        st_path = stat(lock_path)
        (st_path.device == st_tok.device && st_path.inode == st_tok.inode) || return false
        rm(lock_path; force = true)
        return true
    catch
        return false
    finally
        rm(token; force = true)
    end
end

"""
    output_dir_lock!(output_dir; id=nothing) -> release::Function

Exclusive `.distssh.lock` in `output_dir`. The record stores writer, host, pid,
start key, and an optional job id. A live same-host owner or a foreign host
throws. A dead same-host owner, or the same pid with a different start key,
is replaced. The release removes the file only when it is still the acquired
inode and host, pid, and start key still match.
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
    id_s = if id === nothing || String(id) == ""
        ""
    else
        _parse_kit_job_id(String(id))
    end
    body = _output_lock_text(host, mypid, start, id_s)
    function _release_acquired(dev, ino)
        return () -> begin
            try
                isfile(lock_path) || return nothing
                st = stat(lock_path)
                (st.device == dev && st.inode == ino) || return nothing
                raw = read(lock_path, String)
                rec = _parse_output_lock(raw)
                rec === nothing && return nothing
                (rec.host == host && rec.pid == mypid && rec.start == start) || return nothing
                _unlink_output_lock_if_record!(lock_path, raw)
            catch e
                e isa InterruptException && rethrow()
                @debug "output lock: release skipped" exception = (e, catch_backtrace())
            end
            return nothing
        end
    end
    function _acquired()
        st = stat(lock_path)
        return _release_acquired(st.device, st.inode)
    end
    for _ in 1:_OUTPUT_LOCK_TRIES
        _excl_write_lock(lock_path, body) && return _acquired()
        if ispath(lock_path) && !isfile(lock_path)
            throw(ArgumentError("output lock: malformed lock $(lock_path)"))
        end
        raw = try
            read(lock_path, String)
        catch
            ""
        end
        isempty(raw) && continue
        rec = _parse_output_lock(raw)
        if rec === nothing
            throw(ArgumentError("output lock: malformed lock $(lock_path)"))
        end
        if rec.host == host && rec.pid == mypid && rec.start == start
            return _acquired()
        end
        if _output_lock_blocks(rec, host)
            throw(
                ArgumentError(
                    "another DistSSHRun run (pid $(rec.pid) on $(rec.host)) already holds $(lock_path)",
                ),
            )
        end
        _unlink_output_lock_if_record!(lock_path, raw)
    end
    throw(ArgumentError("output lock: could not create $(lock_path)"))
end

"""Job id after the last `_<YYYYMMDDTHHMMSSZ>_` in a leaf name, else `nothing`.

A uniqueness suffix `-<digits>` may sit between that stamp and the id. A name
that ends on the stamp, or on the stamp plus that suffix, has no job id. An
earlier timestamp in the stem is not an id.
"""
function _leaf_job_id(name::AbstractString)::Union{Nothing, String}
    m = match(r"^.*_[0-9]{8}T[0-9]{6}Z(?:-[0-9]+)?(?:_(.*))?$", String(name))
    m === nothing && return nothing
    job = m.captures[1]
    job === nothing && return nothing
    job = String(job)
    occursin(r"^[A-Za-z0-9._:@+-]+$", job) || return nothing
    return job
end

"""Reason string when `dir` must not be pruned, else `nothing`."""
function _output_lock_prune_block(
        dir::AbstractString;
        skip::Union{Nothing, AbstractString} = nothing,
    )::Union{Nothing, String}
    isdir(dir) || return nothing
    host = _output_lock_host()
    skip_path = skip === nothing ? nothing : String(skip)
    locks = String[]
    function _note_lock!(path::AbstractString)
        path in locks && return nothing
        push!(locks, path)
        return nothing
    end
    direct = joinpath(dir, _OUTPUT_LOCK_NAME)
    (ispath(direct) || islink(direct)) && _note_lock!(direct)
    for (root, dirs, files) in walkdir(String(dir))
        _OUTPUT_LOCK_NAME in files && _note_lock!(joinpath(root, _OUTPUT_LOCK_NAME))
        _OUTPUT_LOCK_NAME in dirs && _note_lock!(joinpath(root, _OUTPUT_LOCK_NAME))
    end
    for path in locks
        skip_path !== nothing && path == skip_path && continue
        (islink(path) || !isfile(path)) && return "refusing to prune live lock $(path)"
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
        [ -x /bin/ps ] || return 1
        _cur=\$(TZ=UTC LC_ALL=C /bin/ps -o lstart= -p "\$_pid" 2>/dev/null) || return 1
        _cur=\$(printf '%s' "\$_cur" | sed 's/^[[:space:]]*//;s/[[:space:]]*\$//')
      fi
      [ -n "\$_cur" ] || return 1
      printf '%s' "\$_cur" | od -An -tx1 | tr -d ' \\n'
    }
    _distssh_lock_complete() {
      _f=\$1
      [ -f "\$_f" ] || return 1
      _nw=\$(grep -c '^writer=' "\$_f" 2>/dev/null || true)
      _nh=\$(grep -c '^host=' "\$_f" 2>/dev/null || true)
      _np=\$(grep -c '^pid=' "\$_f" 2>/dev/null || true)
      _ns=\$(grep -c '^start=' "\$_f" 2>/dev/null || true)
      _ni=\$(grep -c '^id=' "\$_f" 2>/dev/null || true)
      [ "\$_nw" = 1 ] && [ "\$_nh" = 1 ] && [ "\$_np" = 1 ] && [ "\$_ns" = 1 ] && [ "\$_ni" = 1 ] || return 1
      _rec_writer=\$(sed -n 's/^writer=//p' "\$_f")
      _rec_host=\$(sed -n 's/^host=//p' "\$_f")
      _rec_pid=\$(sed -n 's/^pid=//p' "\$_f")
      _rec_start=\$(sed -n 's/^start=//p' "\$_f")
      _rec_idv=\$(sed -n 's/^id=//p' "\$_f")
      [ -n "\$_rec_writer" ] && [ -n "\$_rec_host" ] && [ -n "\$_rec_pid" ] && [ -n "\$_rec_start" ] || return 1
      case "\$_rec_pid" in
        ''|*[!0-9]*|0*) return 1 ;;
      esac
      case "\$_rec_host" in
        *"="*) return 1 ;;
      esac
      case "\$_rec_start" in
        *[!0-9a-f]*) return 1 ;;
      esac
      case "\$_rec_idv" in
        "") ;;
        *[!A-Za-z0-9._:@+-]*) return 1 ;;
      esac
      [ \$((\${#_rec_start} % 2)) -eq 0 ] || return 1
      return 0
    }
    _distssh_one_blocks() {
      _f=\$1
      [ -f "\$_f" ] || return 1
      _distssh_lock_complete "\$_f" || return 0
      _rec_writer=\$(sed -n 's/^writer=//p' "\$_f")
      _rec_host=\$(sed -n 's/^host=//p' "\$_f")
      _rec_pid=\$(sed -n 's/^pid=//p' "\$_f")
      _rec_start=\$(sed -n 's/^start=//p' "\$_f")
      case "\$_rec_writer" in
        "DistSSHRun $(maj).$(minr)"|"DistSSHRun $(maj).$(minr)."*) ;;
        *) return 0 ;;
      esac
      _rec_here=\$(hostname)
      [ "\$_rec_host" = "\$_rec_here" ] || return 0
      _alive=0
      if kill -0 "\$_rec_pid" 2>/dev/null; then _alive=1; fi
      if [ -d "/proc/\$_rec_pid" ]; then _alive=1; fi
      if /bin/ps -p "\$_rec_pid" >/dev/null 2>&1; then _alive=1; fi
      [ "\$_alive" = 1 ] || return 1
      _probe_hex=\$(_distssh_start_hex "\$_rec_pid") || return 0
      [ -n "\$_probe_hex" ] || return 0
      [ "\$_probe_hex" = "\$_rec_start" ] && return 0
      return 1
    }
    _distssh_tree_blocks() {
      _root=\$1
      _skip=\$2
      if find "\$_root" -name .distssh.lock -print0 2>/dev/null | od -An -tx1 | grep -q 0a; then
        return 0
      fi
      if [ -n "\$(find "\$_root" -name .distssh.lock ! -type f 2>/dev/null)" ]; then
        return 0
      fi
      _list=\$(find "\$_root" -name .distssh.lock -type f 2>/dev/null) || return 0
      [ -n "\$_list" ] || return 1
      _any=\$(printf '%s\\n' "\$_list" | while IFS= read -r _f; do
        [ -n "\$_skip" ] && [ "\$_f" = "\$_skip" ] && continue
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
        _distssh_unlink_if_same() {
          _path=\$1
          _obs=\$2
          _tok="\${_path}.stale.\$\$"
          ln "\$_path" "\$_tok" 2>/dev/null || return 1
          _cur=\$(cat "\$_tok" 2>/dev/null) || {
            rm -f "\$_tok"
            return 1
          }
          if [ "\$_cur" != "\$_obs" ]; then
            rm -f "\$_tok"
            return 1
          fi
          _i1=\$(stat -c '%i' "\$_path" 2>/dev/null || stat -f '%i' "\$_path" 2>/dev/null)
          _i2=\$(stat -c '%i' "\$_tok" 2>/dev/null || stat -f '%i' "\$_tok" 2>/dev/null)
          rm -f "\$_tok"
          [ -n "\$_i1" ] && [ "\$_i1" = "\$_i2" ] || return 1
          rm -f "\$_path"
          return 0
        }
        _distssh_write_lock() {
          _dir=\$1
          _id=\$2
          _writer=\$3
          _me=\$4
          _hex=\$5
          _tmp=\$(mktemp "\$_dir/.distssh.lock.XXXXXX") || return 1
          printf '%s\\n' "writer=\${_writer}" "host=\${_me}" "pid=\$\$" "start=\${_hex}" "id=\${_id}" > "\$_tmp" || {
            rm -f "\$_tmp"
            return 1
          }
          _base=\$(basename "\$_tmp")
          if ln "\$_tmp" "\$_dir/.distssh.lock" 2>/dev/null; then
            rm -f "\$_tmp"
            if [ -f "\$_dir/.distssh.lock" ]; then
              return 0
            fi
            rm -f "\$_dir/.distssh.lock/\$_base"
            return 1
          fi
          rm -f "\$_tmp"
          return 1
        }
        _distssh_hold_lock() {
          _dir=\$1
          _id=\$2
          [ -d "\$_dir" ] || return 1
          _hex=\$(_distssh_start_hex \$\$) || return 1
          [ -n "\$_hex" ] || return 1
          _me=\$(hostname)
          [ -n "\$_me" ] || return 1
          _writer=$writer_q
          _distssh_write_lock "\$_dir" "\$_id" "\$_writer" "\$_me" "\$_hex" && return 0
          _lf="\$_dir/.distssh.lock"
          [ -f "\$_lf" ] || return 1
          _distssh_lock_complete "\$_lf" || return 1
          _hpid=\$(sed -n 's/^pid=//p' "\$_lf")
          _hstart=\$(sed -n 's/^start=//p' "\$_lf")
          _hhost=\$(sed -n 's/^host=//p' "\$_lf")
          _hwriter=\$(sed -n 's/^writer=//p' "\$_lf")
          if [ "\$_hpid" = "\$\$" ] && [ "\$_hstart" = "\$_hex" ] && [ "\$_hhost" = "\$_me" ] && [ "\$_hwriter" = "\$_writer" ]; then
            return 0
          fi
          _obs=\$(cat "\$_lf") || return 1
          if _distssh_one_blocks "\$_lf"; then
            printf 'output lock held by pid %s on %s\\n' "\$_hpid" "\$_hhost" >&2
            return 1
          fi
          _distssh_unlink_if_same "\$_lf" "\$_obs" || return 1
          _distssh_write_lock "\$_dir" "\$_id" "\$_writer" "\$_me" "\$_hex" || return 1
          return 0
        }
        """
end

"""Statement that writes `.distssh.lock` in a remote directory word. `id` may be empty."""
function output_lock_hold_shell(dir_word::AbstractString, id::AbstractString = "")::String
    id_s = String(id) == "" ? "" : _parse_kit_job_id(String(id))
    return "_distssh_hold_lock $(dir_word) $(posix_quote(id_s))"
end
