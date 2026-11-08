# Push content-hash cache blobs over SSH (project ship excludes `.distsshkit/`).

"""
    cache_remote_dir(remote_root) -> String

Join `remote_root` with `.distsshkit/cache/sha256` (same layout as local
[`cache_relpath`](@ref)).
"""
function cache_remote_dir(remote_root::AbstractString)::String
    return joinpath(String(remote_root), _NS_CACHE_DIR)
end

function _cache_blob_names(
        local_dir::AbstractString,
        hashes::Union{Nothing, AbstractVector{<:AbstractString}},
    )::Vector{String}
    names = if hashes === nothing
        isdir(local_dir) || return String[]
        String[n for n in readdir(local_dir) if length(n) == 64 && all(isxdigit, n)]
    else
        String[lowercase(strip(String(h))) for h in hashes]
    end
    for n in names
        cache_relpath(n)
        isfile(joinpath(local_dir, n)) || throw(
            ArgumentError(
                "push_cache!: missing local blob $(joinpath(local_dir, n))",
            )
        )
    end
    return names
end

const _CACHE_BATCH = 32

# Remote `-e` strings. No single quotes: `posix_quote` wraps the expression.
const _CACHE_LIST_EXPR = """
function _cache_list_main()
    # distssh-cache-list
    dir = ARGS[1]
    isdir(dir) || return nothing
    names = String[]
    for n in readdir(dir)
        length(n) == 64 || continue
        all(c -> c in "0123456789abcdef", n) || continue
        p = joinpath(dir, n)
        islink(p) && continue
        isfile(p) || continue
        push!(names, n)
    end
    sort!(names)
    for n in names
        println(n, " ", filesize(joinpath(dir, n)))
    end
    return nothing
end
_cache_list_main()
"""

const _CACHE_EXTRACT_EXPR = """
using Tar, SHA
function _cache_extract_main()
    # distssh-cache-extract
    cache = ARGS[1]
    parent = dirname(cache)
    t0 = time()
    function process_dead(pid)
        pid <= 0 && return true
        return ccall(:kill, Cint, (Cint, Cint), Cint(pid), Cint(0)) != 0
    end
    function staging_pid(name)
        startswith(name, ".staging-") || return nothing
        rest = SubString(name, ncodeunits(".staging-") + 1)
        dash = findfirst(c -> c == Char(45), rest)
        dash === nothing && return nothing
        return tryparse(Int, rest[1:prevind(rest, dash)])
    end
    if isdir(parent)
        for n in readdir(parent)
            pid = staging_pid(n)
            pid === nothing && continue
            p = joinpath(parent, n)
            isdir(p) || continue
            islink(p) && continue
            stat(p).mtime < t0 || continue
            process_dead(pid) || continue
            rm(p; force = true, recursive = true)
        end
    end
    mkpath(cache)
    stage = joinpath(parent, string(".staging-", getpid(), "-", time_ns()))
    mkdir(stage)
    try
        function take_block(io)
            buf = Vector{UInt8}(undef, 512)
            n = readbytes!(io, buf)
            n == 0 && return nothing
            n == 512 && return buf
            println(stderr, "truncated header")
            exit(1)
        end
        function valid_name(path)
            name = path
            while startswith(name, "./")
                name = SubString(name, 3)
            end
            occursin("/", name) && return nothing
            length(name) == 64 || return nothing
            all(c -> c in "0123456789abcdef", name) || return nothing
            return String(name)
        end
        while true
            block = take_block(stdin)
            block === nothing && break
            all(iszero, block) && break
            hdr = Tar.read_header(IOBuffer(block))
            hdr.type == :file || (println(stderr, "refusing ", hdr.type); exit(2))
            name = valid_name(hdr.path)
            name === nothing && (println(stderr, "bad name"); exit(2))
            tmp = joinpath(stage, name)
            ctx = SHA.SHA256_CTX()
            open(tmp, "w") do out
                buf = Vector{UInt8}(undef, 65536)
                left = hdr.size
                while left > 0
                    k = readbytes!(stdin, buf, min(length(buf), Int(left)))
                    k == 0 && (println(stderr, "truncated entry"); exit(1))
                    SHA.update!(ctx, view(buf, 1:k))
                    write(out, view(buf, 1:k))
                    left -= k
                end
                pad = mod(512 - mod(Int(hdr.size), 512), 512)
                got = readbytes!(stdin, buf, pad)
                got == pad || (println(stderr, "truncated entry"); exit(1))
            end
            hex = SHA.bytes2hex(SHA.digest!(ctx))
            hex == name || (println(stderr, "digest mismatch"); exit(1))
            dest = joinpath(cache, name)
            if islink(dest)
                mv(tmp, dest; force = true)
            elseif isfile(dest) && filesize(dest) == hdr.size
                rm(tmp)
            else
                mv(tmp, dest; force = true)
            end
            println(name)
        end
    finally
        rm(stage; force = true, recursive = true)
    end
    return nothing
end
_cache_extract_main()
"""

"""Lowercase 64-hex digest, or `nothing`."""
function _cache_digest_name(name::AbstractString)::Union{Nothing, String}
    n = String(name)
    length(n) == 64 || return nothing
    all(c -> c in "0123456789abcdef", n) || return nothing
    return n
end

"""`nothing` when every local blob is a lowercase digest of its own bytes."""
function _cache_local_error(local_dir::AbstractString, names::Vector{String})::Union{Nothing, String}
    for n in names
        _cache_digest_name(n) === nothing &&
            return "push_cache!: blob name is not a lowercase sha256: $n"
        path = joinpath(local_dir, n)
        islink(path) && return "push_cache!: refusing symlink $path"
        isfile(path) || return "push_cache!: missing local blob $path"
        file_sha256(path) == n || return "push_cache!: blob contents do not match $n"
    end
    return nothing
end

function _parse_cache_list(text::AbstractString)::Dict{String, Int}
    out = Dict{String, Int}()
    for raw in eachsplit(text, '\n'; keepempty = false)
        parts = split(String(raw))
        length(parts) == 2 || throw(ArgumentError("cache list line was not name and size"))
        name = _cache_digest_name(String(parts[1]))
        name === nothing && throw(ArgumentError("cache list name was not a lowercase sha256"))
        sz = tryparse(Int, String(parts[2]))
        sz === nothing && throw(ArgumentError("cache list size was not an integer"))
        out[name] = sz
    end
    return out
end

function _parse_cache_accepted(text::AbstractString)::Vector{String}
    names = String[]
    for raw in eachsplit(text, '\n'; keepempty = false)
        name = _cache_digest_name(strip(String(raw)))
        name === nothing && continue
        push!(names, name)
    end
    return names
end

"""
Send `pending` in batches of 32. `send!(batch)` returns `(exitcode, accepted names)`.
A non-zero exit is tried once more. Returns an error string, or `nothing`.
"""
function _cache_push_pending!(send!::Function, pending::Vector{String})::Union{Nothing, String}
    left = copy(pending)
    while !isempty(left)
        batch = left[1:min(_CACHE_BATCH, length(left))]
        wanted = Set(batch)
        code, accepted = send!(batch)::Tuple{Int, Vector{String}}
        if code != 0
            code, accepted = send!(batch)::Tuple{Int, Vector{String}}
            code != 0 && return "cache tar failed"
        end
        got = Set(accepted)
        progressed = any(name -> name in got, wanted)
        progressed || return "cache tar accepted nothing"
        left = [name for name in left if !(name in wanted && name in got)]
    end
    return nothing
end

function _cache_send_batch(
        host::AbstractString,
        julia_bin::AbstractString,
        remote_dir::AbstractString,
        local_dir::AbstractString,
        names::Vector{String},
    )::Tuple{Int, Vector{String}}
    wanted = Set(names)
    script = _remote_stdlib_julia_e(
        julia_bin,
        _CACHE_EXTRACT_EXPR;
        args = String[_remote_shell_path_word(remote_dir)],
    )
    out_buf = IOBuffer()
    err_buf = IOBuffer()
    cmd = _host_sync_remote_shell_cmd(String(host), script; forward_stdin = true)
    proc = open(pipeline(ignorestatus(cmd); stdout = out_buf, stderr = err_buf); write = true)
    try
        Tar.create(local_dir, proc) do path
            path == local_dir && return true
            return basename(path) in wanted
        end
    catch
        # The remote closed stdin after a short or rejected stream.
    finally
        close(proc)
    end
    wait(proc)
    code = DistSSHBase.shell_status(proc)
    return code, _parse_cache_accepted(String(take!(out_buf)))
end

function _tar_cache_one_host!(
        host::AbstractString,
        local_dir::AbstractString,
        remote_dir::AbstractString,
        files::Vector{String},
    )::HostResult
    h = String(host)
    local_err = _cache_local_error(local_dir, files)
    local_err === nothing || return HostResult(h, false, local_err)
    if !_ensure_remote_dir(h, remote_dir)
        return HostResult(h, false, "could not create remote cache directory")
    end
    julia_bin = if _test_doubles_on()
        w = strip(get(ENV, "DISTSSHKIT_TEST_JULIA_WHICH", ""))
        isempty(w) ? "/usr/bin/julia" : w
    else
        try
            pin_remote_julia(h)
        catch e
            _rethrow_missing_host_tool(e)
            return HostResult(h, false, sprint(showerror, e))
        end
    end
    julia_bin === nothing && return HostResult(h, false, "Julia not found on remote host $h")
    try
        list_sh = _remote_stdlib_julia_e(
            julia_bin,
            _CACHE_LIST_EXPR;
            args = String[_remote_shell_path_word(remote_dir)],
        )
        code, listed = _remote_shell_status(h, list_sh)
        code == 0 || return HostResult(h, false, "cache list failed")
        remote_sizes = _parse_cache_list(listed)
        pending = String[]
        for n in files
            sz = get(remote_sizes, n, nothing)
            sz === filesize(joinpath(local_dir, n)) && continue
            push!(pending, n)
        end
        isempty(pending) && return HostResult(h, true, "cache tar ok")
        err = _cache_push_pending!(pending) do batch
            return _cache_send_batch(h, julia_bin, remote_dir, local_dir, batch)
        end
        err === nothing || return HostResult(h, false, err)
        return HostResult(h, true, "cache tar ok")
    catch e
        _rethrow_missing_host_tool(e)
        return HostResult(h, false, sprint(showerror, e))
    end
end

"""
    push_cache!(session; hashes=nothing) -> SyncResult

Stream local `.distsshkit/cache/sha256/` blobs onto each SSH host with stdlib
Tar. Does not delete remote blobs that were not in this push.
Hosts run at most `DISTSSHKIT_JOBS` at a time (default 1). Host result order
matches `session.hosts`.
Project `setup ship-tree` still excludes `.distsshkit/`; this call is the
dedicated transfer.

`hashes` limits the push to those digests. `nothing` pushes every local blob.
No SSH hosts → error. Empty cache → success with no host rows.
"""
function push_cache!(
        session::KitSession;
        hashes::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
    )::SyncResult
    isempty(session.hosts) && throw(
        ArgumentError(
            explain_no_hosts(; surface = hint_surface(session), kind = :ssh),
        )
    )
    return _with_kit_inproc_run!(:sync) do
        apply_session_env!(session)
        local_dir = joinpath(session.project, _NS_CACHE_DIR)
        files = _cache_blob_names(local_dir, hashes)
        isempty(files) && return SyncResult(false, HostResult[]; ok = true)
        remote_dir = cache_remote_dir(session_remote_root(session))
        results = Vector{HostResult}(undef, length(session.hosts))
        map_host_jobs(session.hosts) do i, host
            results[i] = _tar_cache_one_host!(host, local_dir, remote_dir, files)
        end
        return SyncResult(false, results; ok = all(r -> r.ok, results))
    end
end
