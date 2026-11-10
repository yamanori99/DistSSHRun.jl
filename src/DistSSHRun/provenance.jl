# Provenance recorded with a run. Failure to record does not fail the job.
# Worker values come from the process Kit started (`Core.eval` of a Base-only
# expression). The job project does not need DistSSHRun loaded.

const _PROVENANCE_SOURCE = Ref{Union{Nothing, AbstractDict}}(nothing)
const _PROVENANCE_WORKERS = Ref{Union{Nothing, Dict{String, Any}}}(nothing)
const _PROVENANCE_PROJECT = Ref{String}("")
const _PROVENANCE_LOCK = ReentrantLock()
const _PROVENANCE_AT_START = Ref(false)
const _PROVENANCE_PROJECT_SNAP = Ref{Union{Nothing, Dict{String, Any}}}(nothing)
const _PROVENANCE_SOURCE_SNAP = Ref{Union{Nothing, Dict{String, Any}}}(nothing)
const _PROVENANCE_GIT_TOOL = Ref{Union{Nothing, Dict{String, Any}}}(nothing)
const _PROVENANCE_GO = Pair{String, String}[]

const _GO_SLOT_PROVENANCE_NAME = "provenance-slot.toml"
const _GO_SLOT_LOADER_NAME = "provenance-slot.jl"

# Same fields as `_process_snapshot_expr`. A go slot has no DistSSHRun, so `-L` runs this text.
const _GO_SLOT_LOADER_SRC = let _go_slot_state_dir = DistSSHBase.LOCAL_STATE_DIR
    """
    import TOML
    try
        let blas = Ref("not loaded"), blas_threads = Ref("not loaded")
            for (pkg, mod) in Base.loaded_modules
                pkg.name == "LinearAlgebra" || continue
                try
                    libs = mod.BLAS.get_config().loaded_libs
                    if !isempty(libs)
                        blas[] = string(first(libs).libname)
                    end
                    blas_threads[] = string(mod.BLAS.get_num_threads())
                catch
                    blas[] = "not loaded"
                    blas_threads[] = "not loaded"
                end
            end
            snap = Dict{String, String}(
                "version" => string(VERSION),
                "commit" => string(Base.GIT_VERSION_INFO.commit),
                "cpu" => string(Sys.CPU_NAME),
                "machine" => string(Sys.MACHINE),
                "kernel" => string(Sys.KERNEL),
                "nthreads" => string(Threads.nthreads()),
                "hostname" => string(gethostname()),
                "blas" => blas[],
                "blas_threads" => blas_threads[],
            )
            # Same walk as `_julia_install_name`. This script cannot load DistSSHRun.
            if isabspath(Sys.BINDIR)
                dir = Sys.BINDIR
                parent = dirname(dir)
                while parent != dir
                    name = basename(parent)
                    if startswith(name, "julia-")
                        snap["install"] = name
                        break
                    end
                    dir = parent
                    parent = dirname(dir)
                end
            end
            dir = get(ENV, "DISTRIBUTED_OUTPUT_DIR", pwd())
            dest = joinpath(dir, $(_go_slot_state_dir |> repr))
            mkpath(dest)
            open(joinpath(dest, "provenance-slot.toml"), "w") do io
                TOML.print(io, snap)
            end
        end
    catch
    end
    """
end

const _GIT_DIFF_FLAGS = (
    "-c",
    "core.quotepath=off",
    "diff",
    "--no-ext-diff",
    "--no-textconv",
    "--no-color",
    "--binary",
    "HEAD",
)

const _PROVENANCE_SOURCE_ENV = (
    commit = "DISTSSH_SOURCE_COMMIT",
    dirty = "DISTSSH_SOURCE_DIRTY",
    captured = "DISTSSH_SOURCE_CAPTURED",
    untracked = "DISTSSH_SOURCE_UNTRACKED",
)

const _SNAP_KEYS = (
    "version",
    "commit",
    "cpu",
    "machine",
    "kernel",
    "nthreads",
    "blas",
    "blas_threads",
    "hostname",
    "install",
)

# `install` is optional. A Julia that is not under a `julia-*` directory omits it.
# The other keys stay required so a partial snapshot is still an error.
function _julia_install_name(bindir::AbstractString)::Union{Nothing, String}
    path = String(bindir)
    (isempty(path) || !isabspath(path)) && return nothing
    dir = path
    parent = dirname(dir)
    while parent != dir
        name = basename(parent)
        startswith(name, "julia-") && return name
        dir = parent
        parent = dirname(dir)
    end
    return nothing
end

"""Base-only expression. Safe to `Core.eval` on a worker that has no DistSSHRun."""
function _process_snapshot_expr()
    return quote
        let blas = Ref("not loaded"), blas_threads = Ref("not loaded")
            for (pkg, mod) in Base.loaded_modules
                pkg.name == "LinearAlgebra" || continue
                try
                    libs = mod.BLAS.get_config().loaded_libs
                    if !isempty(libs)
                        blas[] = string(first(libs).libname)
                    end
                    blas_threads[] = string(mod.BLAS.get_num_threads())
                catch
                    blas[] = "not loaded"
                    blas_threads[] = "not loaded"
                end
            end
            snap = Dict{String, String}(
                "version" => string(VERSION),
                "commit" => string(Base.GIT_VERSION_INFO.commit),
                "cpu" => string(Sys.CPU_NAME),
                "machine" => string(Sys.MACHINE),
                "kernel" => string(Sys.KERNEL),
                "nthreads" => string(Threads.nthreads()),
                "hostname" => string(gethostname()),
                "blas" => blas[],
                "blas_threads" => blas_threads[],
            )
            # Same walk as `_julia_install_name`. A worker cannot load DistSSHRun.
            if isabspath(Sys.BINDIR)
                dir = Sys.BINDIR
                parent = dirname(dir)
                while parent != dir
                    name = basename(parent)
                    if startswith(name, "julia-")
                        snap["install"] = name
                        break
                    end
                    dir = parent
                    parent = dirname(dir)
                end
            end
            snap
        end
    end
end

function _reset_run_provenance!(project::AbstractString)
    proj = canonical_local_path(String(project))
    _PROVENANCE_PROJECT[] = proj
    _PROVENANCE_WORKERS[] = nothing
    lock(_PROVENANCE_LOCK) do
        empty!(_PROVENANCE_GO)
    end
    # Taken now. A long run must not record edits made while it was going.
    # A bad Project.toml, an unreadable manifest, or a git status that is not
    # text must not fail the job. `assemble_provenance` already swallows this.
    _PROVENANCE_PROJECT_SNAP[] = try
        _project_provenance(proj)
    catch
        Dict{String, Any}("manifest" => "absent")
    end
    _PROVENANCE_SOURCE_SNAP[] = try
        _resolve_source(proj)
    catch
        nothing
    end
    # Same moment as the source snapshot. A later PATH change must not
    # record a different git from the one this snapshot used.
    _PROVENANCE_GIT_TOOL[] = try
        _path_resolved_git()
    catch
        nothing
    end
    _PROVENANCE_AT_START[] = true
    reset_worker_seeds!()
    return nothing
end

"""Write the go-slot `-L` file. `nothing` when the directory cannot be written."""
function write_go_slot_loader(slot_dir::AbstractString)::Union{Nothing, String}
    return try
        dest = joinpath(slot_dir, DistSSHBase.LOCAL_STATE_DIR)
        mkpath(dest)
        path = joinpath(dest, _GO_SLOT_LOADER_NAME)
        write(path, _GO_SLOT_LOADER_SRC)
        path
    catch
        nothing
    end
end

"""Remember one go slot. `assemble_provenance` reads the toml after the slot exits."""
function note_go_slot_provenance!(token::AbstractString, slot_dir::AbstractString)
    path = joinpath(String(slot_dir), DistSSHBase.LOCAL_STATE_DIR, _GO_SLOT_PROVENANCE_NAME)
    lock(_PROVENANCE_LOCK) do
        push!(_PROVENANCE_GO, String(token) => path)
    end
    return nothing
end

function _set_provenance_source!(source::Union{Nothing, AbstractDict})
    _PROVENANCE_SOURCE[] = source
    return nothing
end

function _provenance_lookup(d::AbstractDict, key::String)
    haskey(d, key) && return d[key]
    sym = Symbol(key)
    haskey(d, sym) && return d[sym]
    return nothing
end

const _SHA256_BUF = 1 << 16
const _SHA256_EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
const _SHA256_OPENSSL = Ref{Union{Nothing, Bool}}(nothing)

"""SHA-256 hex from `feed!` via stdlib `SHA`. `feed!` returns 0 at the end."""
function _sha256_stdlib(feed!::Function)::String
    ctx = SHA.SHA256_CTX()
    buf = Vector{UInt8}(undef, _SHA256_BUF)
    while true
        n = feed!(buf)
        n == 0 && break
        SHA.update!(ctx, view(buf, 1:n))
    end
    return SHA.bytes2hex(SHA.digest!(ctx))
end

"""SHA-256 hex from `feed!` via OpenSSL EVP. `feed!` returns 0 at the end."""
function _sha256_openssl(feed!::Function)::String
    ctx = ccall((:EVP_MD_CTX_new, OpenSSL_jll.libcrypto), Ptr{Cvoid}, ())
    ctx == C_NULL && error("EVP_MD_CTX_new failed")
    try
        md = ccall((:EVP_sha256, OpenSSL_jll.libcrypto), Ptr{Cvoid}, ())
        md == C_NULL && error("EVP_sha256 failed")
        ccall((:EVP_DigestInit_ex, OpenSSL_jll.libcrypto), Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), ctx, md, C_NULL) == 1 ||
            error("EVP_DigestInit_ex failed")
        buf = Vector{UInt8}(undef, _SHA256_BUF)
        while true
            n = feed!(buf)
            n == 0 && break
            GC.@preserve buf ccall(
                (:EVP_DigestUpdate, OpenSSL_jll.libcrypto),
                Cint,
                (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                ctx,
                buf,
                n,
            ) == 1 || error("EVP_DigestUpdate failed")
        end
        out = Vector{UInt8}(undef, 32)
        ccall(
            (:EVP_DigestFinal_ex, OpenSSL_jll.libcrypto),
            Cint,
            (Ptr{Cvoid}, Ptr{UInt8}, Ptr{Cuint}),
            ctx,
            out,
            C_NULL,
        ) == 1 || error("EVP_DigestFinal_ex failed")
        return SHA.bytes2hex(out)
    finally
        ccall((:EVP_MD_CTX_free, OpenSSL_jll.libcrypto), Cvoid, (Ptr{Cvoid},), ctx)
    end
end

"""True when an empty OpenSSL SHA-256 matches stdlib `SHA`. Cached for the process."""
function _openssl_sha256_ok()::Bool
    cached = _SHA256_OPENSSL[]
    cached === nothing || return cached
    ok = try
        _sha256_openssl(_ -> 0) == _SHA256_EMPTY
    catch e
        e isa InterruptException && rethrow()
        false
    end
    _SHA256_OPENSSL[] = ok
    return ok
end

"""SHA-256 hex. OpenSSL EVP when the empty probe succeeds; stdlib `SHA` otherwise."""
function _sha256_stream(feed!::Function)::String
    return _openssl_sha256_ok() ? _sha256_openssl(feed!) : _sha256_stdlib(feed!)
end

"""SHA-256 hex of `bytes`, streamed. Same digest as hashing the bytes in one shot."""
function _sha256_hex(bytes::AbstractVector{UInt8})::String
    pos = Ref(1)
    return _sha256_stream() do buf
        pos[] > length(bytes) && return 0
        n = min(length(buf), length(bytes) - pos[] + 1)
        copyto!(buf, 1, bytes, pos[], n)
        pos[] += n
        return n
    end
end

"""SHA-256 hex of the file at `path`, streamed. Does not read the whole file first."""
function _sha256_file(path::AbstractString)::String
    return open(path, "r") do io
        return _sha256_stream() do buf
            return readbytes!(io, buf)
        end
    end
end

"""SHA-256 of `cmd`'s stdout, read in chunks. `nothing` when the process fails."""
function _sha256_process(cmd::Cmd)::Union{Nothing, String}
    ctx = SHA.SHA256_CTX()
    local proc
    try
        proc = open(pipeline(ignorestatus(cmd); stderr = devnull); read = true)
        while !eof(proc)
            chunk = read(proc, 1 << 16)
            isempty(chunk) && break
            SHA.update!(ctx, chunk)
        end
        close(proc)
        wait(proc)
    catch
        return nothing
    end
    DistSSHBase.shell_status(proc) == 0 || return nothing
    return SHA.bytes2hex(SHA.digest!(ctx))
end

function _snapshot_dict(raw)::Dict{String, String}
    raw isa AbstractDict || return Dict{String, String}("error" => "snapshot was not a dict")
    out = Dict{String, String}()
    for (k, v) in raw
        string(k) == "pmap_items" && continue
        out[string(k)] = string(v)
    end
    for key in _SNAP_KEYS
        key == "install" && continue
        haskey(out, key) || return Dict{String, String}("error" => "incomplete snapshot")
    end
    if get(out, "install", "") == ""
        delete!(out, "install")
    end
    return out
end

function _local_process_snapshot()::Dict{String, String}
    return try
        _snapshot_dict(Core.eval(Main, _process_snapshot_expr()))
    catch e
        Dict{String, String}("error" => sprint(showerror, e))
    end
end

"""Fetch one worker. A dead pid returns `error` and does not throw."""
function _fetch_process_snapshot(pid::Integer)::Dict{String, String}
    return try
        _snapshot_dict(remotecall_fetch(Core.eval, Int(pid), Main, _process_snapshot_expr()))
    catch e
        Dict{String, String}("error" => sprint(showerror, e))
    end
end

function _blas_threads_value(raw::AbstractString)
    n = tryparse(Int, String(raw))
    return n === nothing ? String(raw) : n
end

function _group_key(snap::Dict{String, String})::String
    haskey(snap, "error") && return "error\0" * snap["error"]
    return join(
        (k == "install" ? get(snap, k, "") : snap[k] for k in _SNAP_KEYS),
        '\0',
    )
end

function _group_body(snap::Dict{String, String})::Dict{String, Any}
    if haskey(snap, "error")
        return Dict{String, Any}("error" => snap["error"], "n" => 1)
    end
    body = Dict{String, Any}(
        "version" => snap["version"],
        "commit" => snap["commit"],
        "cpu" => snap["cpu"],
        "machine" => snap["machine"],
        "kernel" => snap["kernel"],
        "nthreads" => something(tryparse(Int, snap["nthreads"]), 0),
        "blas" => snap["blas"],
        "blas_threads" => _blas_threads_value(snap["blas_threads"]),
        "hostname" => snap["hostname"],
        "n" => 1,
    )
    install = get(snap, "install", "")
    isempty(install) || (body["install"] = install)
    return body
end

"""Collapse identical snapshots. One placement token, one list of groups."""
function _group_snapshots(snaps::AbstractVector{<:AbstractDict})::Vector{Dict{String, Any}}
    order = String[]
    groups = Dict{String, Dict{String, Any}}()
    for raw in snaps
        snap = raw isa Dict{String, String} ? raw : _snapshot_dict(raw)
        key = _group_key(snap)
        if haskey(groups, key)
            groups[key]["n"] = groups[key]["n"] + 1
        else
            groups[key] = _group_body(snap)
            push!(order, key)
        end
    end
    return Dict{String, Any}[groups[k] for k in order]
end

function _provenance_token(host::AbstractString)::String
    h = String(host)
    h == PARENT_HOST_NAME && return h
    startswith(h, "child:") && return h
    return "child:" * h
end

"""Read `DRIVE_HOST_WORKER_IDS` now. Later `rmprocs` does not erase this."""
function capture_worker_provenance!()
    try
        grouped = Dict{String, Any}()
        hosts = Pair{String, Vector{Int}}[
            String(host) => Int[Int(i) for i in ids] for (host, ids) in DRIVE_HOST_WORKER_IDS
        ]
        for (host, ids) in hosts
            snaps = Dict{String, String}[_fetch_process_snapshot(pid) for pid in ids]
            grouped[_provenance_token(host)] = _group_snapshots(snaps)
        end
        _PROVENANCE_WORKERS[] = grouped
    catch
        _PROVENANCE_WORKERS[] = Dict{String, Any}()
    end
    return nothing
end

function _project_provenance(project::AbstractString)::Dict{String, Any}
    out = Dict{String, Any}()
    manifest = manifest_path(project)
    if manifest isa String
        out["manifest"] = _sha256_hex(read(manifest))
        parsed = try
            TOML.parsefile(manifest)
        catch
            nothing
        end
        if parsed isa AbstractDict && haskey(parsed, "julia_version")
            out["julia_version"] = string(parsed["julia_version"])
        end
    else
        out["manifest"] = "absent"
    end
    locks = Dict{String, String}()
    for name in ("CondaPkg.toml", "conda-lock.yml", "pixi.lock")
        path = joinpath(project, name)
        isfile(path) || continue
        locks[name] = _sha256_hex(read(path))
    end
    isempty(locks) || (out["locks"] = locks)
    return out
end

function _seed_provenance()::Union{Nothing, Dict{String, Any}}
    seed = _JOB_SEED[]
    workers = Dict{String, Any}[]
    if seed !== nothing
        for rank in _ASSIGNED_RANKS
            push!(workers, Dict{String, Any}("rank" => rank, "seed" => string(worker_seed(seed, rank))))
        end
    end
    items = Dict{String, Any}[]
    lock(_ITEM_LOCK) do
        for key in sort!(collect(keys(_ITEM_MAP)))
            call, item = key
            push!(
                items, Dict{String, Any}(
                    "call" => call,
                    "item" => item,
                    "rank" => _ITEM_MAP[key],
                )
            )
        end
    end
    _append_go_slot_items!(items)
    isempty(workers) && isempty(items) && return nothing
    data = Dict{String, Any}()
    seed === nothing || (data["job"] = string(seed))
    isempty(workers) || (data["workers"] = workers)
    isempty(items) || (data["items"] = items)
    return data
end

function _git_capture_bytes(cmd::Cmd)::Union{Nothing, Vector{UInt8}}
    out = IOBuffer()
    ok = try
        proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = devnull))
        DistSSHBase.shell_status(proc) == 0
    catch
        false
    end
    return ok ? take!(out) : nothing
end

function _git_capture(cmd::Cmd)::Union{Nothing, String}
    raw = _git_capture_bytes(cmd)
    raw === nothing && return nothing
    return try
        String(raw)
    catch
        nothing
    end
end

"""`(xy, path)` from `git status --porcelain=v1 -z`.

A rename or copy is `XY new\\0old\\0`. `path` is the new name. The old name is skipped.
"""
function _git_status_records(raw::AbstractVector{UInt8})::Vector{Tuple{String, String}}
    parts = split(String(raw), '\0'; keepempty = false)
    out = Tuple{String, String}[]
    i = 1
    while i <= length(parts)
        rec = String(parts[i])
        i += 1
        ncodeunits(rec) < 3 && continue
        xy = rec[1:2]
        path = rec[4:end]
        if xy[1] in ('R', 'C') || xy[2] in ('R', 'C')
            i <= length(parts) && (i += 1)
        end
        push!(out, (xy, path))
    end
    return out
end

"""Git record of `project`, or `nothing` when git is missing or this is not a work tree.

Keys: `commit`, `dirty`, `diff_sha256`, `captured`, `untracked`.
`captured` is `"run"`. `dirty` is a `Bool`. `untracked` is an `Int`.
Schema 1 `run.toml` / `provenance.toml` omit `diff_sha256`; the snapshot
dict still has it for Queue.
`.distsshkit/` and `.distsshqueue/` are not uncommitted changes.
"""
function git_source_snapshot(project::AbstractString)::Union{Nothing, Dict{String, Any}}
    return _git_source(project)
end

public git_source_snapshot

"""Kit and Queue write these directories inside the caller's tree. They are not the caller's edits."""
function _git_status_is_kit(path::AbstractString)::Bool
    for name in (
            DistSSHBase.LOCAL_STATE_DIR,
            DistSSHBase.LEGACY_LOCAL_STATE_DIR,
            ".distsshqueue",
        )
        path == name && return true
        startswith(path, name * "/") && return true
        occursin("/" * name * "/", path) && return true
    end
    return false
end

function _toml_int(value)::Union{Nothing, Int}
    value isa Bool && return nothing
    value isa Integer && return Int(value)
    value isa AbstractString || return nothing
    return tryparse(Int, strip(String(value)))
end

"""Item rows a go slot wrote into its snapshot. Each row gains `slot`."""
function _read_go_slot_items(path::AbstractString, token::AbstractString)::Vector{Dict{String, Any}}
    isfile(path) || return Dict{String, Any}[]
    raw = try
        TOML.parsefile(path)
    catch
        return Dict{String, Any}[]
    end
    raw isa AbstractDict || return Dict{String, Any}[]
    listed = get(raw, "pmap_items", nothing)
    listed isa AbstractVector || return Dict{String, Any}[]
    label = basename(dirname(dirname(String(path))))
    slot = string(_provenance_token(token), "/", label)
    out = Dict{String, Any}[]
    for row in listed
        row isa AbstractDict || continue
        call = _toml_int(get(row, "call", nothing))
        item = _toml_int(get(row, "item", nothing))
        rank = _toml_int(get(row, "rank", nothing))
        (call === nothing || item === nothing || rank === nothing) && continue
        push!(
            out, Dict{String, Any}(
                "call" => call,
                "item" => item,
                "rank" => rank,
                "slot" => slot,
            )
        )
    end
    return out
end

function _append_go_slot_items!(items::Vector{Dict{String, Any}})
    rows = lock(_PROVENANCE_LOCK) do
        return Pair{String, String}[_PROVENANCE_GO...]
    end
    for (token, path) in rows
        append!(items, _read_go_slot_items(path, token))
    end
    return nothing
end

"""Write this process's `worker_pmap` rows into the go-slot snapshot. No-op elsewhere."""
function _flush_go_slot_pmap_items!()
    try
        dir = strip(get(ENV, "DISTRIBUTED_OUTPUT_DIR", ""))
        isempty(dir) && return nothing
        path = joinpath(dir, DistSSHBase.LOCAL_STATE_DIR, _GO_SLOT_PROVENANCE_NAME)
        isfile(path) || return nothing
        listed = Dict{String, Any}[]
        lock(_ITEM_LOCK) do
            for key in sort!(collect(keys(_ITEM_MAP)))
                call, item = key
                push!(
                    listed, Dict{String, Any}(
                        "call" => call,
                        "item" => item,
                        "rank" => _ITEM_MAP[key],
                    )
                )
            end
        end
        isempty(listed) && return nothing
        parsed = TOML.parsefile(path)
        raw = parsed isa AbstractDict ? Dict{String, Any}(string(k) => v for (k, v) in parsed) : Dict{String, Any}()
        raw["pmap_items"] = listed
        tmp = path * ".tmp"
        open(tmp, "w") do io
            TOML.print(io, raw)
        end
        mv(tmp, path; force = true)
    catch
    end
    return nothing
end

atexit(_flush_go_slot_pmap_items!)

"""PATH-resolved `git`, noted as outside the Manifest. `nothing` when `git` is absent."""
function _path_resolved_git()::Union{Nothing, Dict{String, Any}}
    path = Sys.which("git")
    path isa AbstractString || return nothing
    return Dict{String, Any}(
        "name" => "git",
        "path" => path,
        "outside_manifest" => true,
    )
end

function _git_source(project::AbstractString)::Union{Nothing, Dict{String, Any}}
    git = Sys.which("git")
    git === nothing && return nothing
    inside = _git_capture(`$git -C $project rev-parse --is-inside-work-tree`)
    inside === nothing && return nothing
    strip(inside) == "true" || return nothing
    head = _git_capture(`$git -C $project rev-parse HEAD`)
    head === nothing && return nothing
    status = _git_capture_bytes(
        `$git -C $project status --porcelain=v1 -z --untracked-files=all`,
    )
    status === nothing && return nothing
    diff_sha = _sha256_process(Cmd([git, "-C", String(project), _GIT_DIFF_FLAGS...]))
    diff_sha === nothing && return nothing
    records = Tuple{String, String}[
        rec for rec in _git_status_records(status) if !_git_status_is_kit(rec[2])
    ]
    untracked = count(rec -> rec[1] == "??", records)
    return Dict{String, Any}(
        "commit" => strip(head),
        "dirty" => !isempty(records),
        "diff_sha256" => diff_sha,
        "captured" => "run",
        "untracked" => untracked,
    )
end

function _source_from_user(source::AbstractDict)::Dict{String, Any}
    out = Dict{String, Any}()
    for key in ("commit", "captured")
        value = _provenance_lookup(source, key)
        value === nothing || (out[key] = string(value))
    end
    dirty = _provenance_lookup(source, "dirty")
    if dirty isa Bool
        out["dirty"] = dirty
    elseif dirty isa AbstractString
        s = lowercase(strip(String(dirty)))
        s == "true" && (out["dirty"] = true)
        s == "false" && (out["dirty"] = false)
    end
    untracked = _provenance_lookup(source, "untracked")
    if untracked isa Integer && !(untracked isa Bool)
        out["untracked"] = Int(untracked)
    elseif untracked isa AbstractString
        n = tryparse(Int, strip(String(untracked)))
        n === nothing || (out["untracked"] = n)
    end
    return out
end

function _source_from_env()::Union{Nothing, Dict{String, Any}}
    haskey(ENV, _PROVENANCE_SOURCE_ENV.commit) || return nothing
    raw = Dict{String, Any}(
        "commit" => ENV[_PROVENANCE_SOURCE_ENV.commit],
    )
    for (field, envk) in (
            :dirty => _PROVENANCE_SOURCE_ENV.dirty,
            :captured => _PROVENANCE_SOURCE_ENV.captured,
            :untracked => _PROVENANCE_SOURCE_ENV.untracked,
        )
        haskey(ENV, envk) && (raw[String(field)] = ENV[envk])
    end
    built = _source_from_user(raw)
    return isempty(built) ? nothing : built
end

"""Drop inherited `DISTSSH_SOURCE_*` keys that this explicit `source` did not set.

`_execute_detached_env` copies the parent environment first. A partial `source`
would otherwise keep stale fields from that copy.
"""
function _drop_unspecified_source_env!(
        env::AbstractDict,
        source::Union{Nothing, AbstractDict},
        extra::AbstractDict,
    )
    source === nothing && return env
    for (_, envk) in pairs(_PROVENANCE_SOURCE_ENV)
        haskey(extra, envk) || delete!(env, envk)
    end
    return env
end

"""Env for a detached child. Empty when `source` is `nothing`."""
function _provenance_source_env(source::Union{Nothing, AbstractDict})::Dict{String, String}
    source === nothing && return Dict{String, String}()
    built = _source_from_user(source)
    out = Dict{String, String}()
    for (field, envk) in pairs(_PROVENANCE_SOURCE_ENV)
        haskey(built, String(field)) || continue
        value = built[String(field)]
        out[envk] = value isa Bool ? (value ? "true" : "false") : string(value)
    end
    return out
end

function _resolve_source(project::AbstractString)::Union{Nothing, Dict{String, Any}}
    explicit = _PROVENANCE_SOURCE[]
    if explicit !== nothing
        built = _source_from_user(explicit)
        return isempty(built) ? nothing : built
    end
    from_env = _source_from_env()
    from_env === nothing || return from_env
    raw = _git_source(project)
    raw === nothing && return nothing
    built = _source_from_user(raw)
    return isempty(built) ? nothing : built
end

function _parent_sections(snap::Dict{String, String})::Tuple{Dict{String, Any}, Dict{String, Any}}
    if haskey(snap, "error")
        err = Dict{String, Any}("error" => snap["error"])
        return (err, Dict{String, Any}())
    end
    julia = Dict{String, Any}(
        "version" => snap["version"],
        "commit" => snap["commit"],
    )
    install = get(snap, "install", "")
    isempty(install) || (julia["install"] = install)
    machine = Dict{String, Any}(
        "cpu" => snap["cpu"],
        "machine" => snap["machine"],
        "kernel" => snap["kernel"],
        "nthreads" => something(tryparse(Int, snap["nthreads"]), 0),
        "blas" => snap["blas"],
        "blas_threads" => _blas_threads_value(snap["blas_threads"]),
        "hostname" => snap["hostname"],
    )
    return (julia, machine)
end

function _read_go_slot_snapshot(path::AbstractString)::Dict{String, String}
    isfile(path) || return Dict{String, String}("error" => "missing snapshot")
    return try
        _snapshot_dict(TOML.parsefile(path))
    catch e
        Dict{String, String}("error" => sprint(showerror, e))
    end
end

"""Go slots grouped by placement token, or `nothing` when this run is not `go`."""
function _go_worker_section()::Union{Nothing, Dict{String, Any}}
    rows = lock(_PROVENANCE_LOCK) do
        return Pair{String, String}[_PROVENANCE_GO...]
    end
    isempty(rows) && return nothing
    by_token = Dict{String, Vector{Dict{String, String}}}()
    order = String[]
    for (token, path) in rows
        key = _provenance_token(token)
        if !haskey(by_token, key)
            push!(order, key)
        end
        push!(get!(by_token, key, Dict{String, String}[]), _read_go_slot_snapshot(path))
    end
    grouped = Dict{String, Any}()
    for key in order
        grouped[key] = _group_snapshots(by_token[key])
    end
    return grouped
end

function _worker_section()::Any
    go = _go_worker_section()
    go === nothing || return go
    grouped = _PROVENANCE_WORKERS[]
    grouped === nothing && return Any[]
    isempty(grouped) && return Any[]
    return grouped
end

"""Full `[provenance]` table. Never throws."""
function assemble_provenance(project::AbstractString = "")::Dict{String, Any}
    return try
        _assemble_provenance(project)
    catch
        Dict{String, Any}(
            "project" => Dict{String, Any}("manifest" => "absent"),
            "workers" => Any[],
        )
    end
end

function _assemble_provenance(project::AbstractString)::Dict{String, Any}
    proj = strip(String(project))
    isempty(proj) && (proj = _PROVENANCE_PROJECT[])
    isempty(proj) && (proj = pwd())
    proj = canonical_local_path(proj)
    parent = _local_process_snapshot()
    julia, machine = _parent_sections(parent)
    started = _PROVENANCE_AT_START[] && canonical_local_path(_PROVENANCE_PROJECT[]) == proj
    project_table = if started
        something(_PROVENANCE_PROJECT_SNAP[], Dict{String, Any}("manifest" => "absent"))
    else
        _project_provenance(proj)
    end
    data = Dict{String, Any}(
        "schema" => 1,
        "writer" => "DistSSHRun $(dist_ssh_kit_version())",
        "julia" => Dict{String, Any}("parent" => julia),
        "machine" => Dict{String, Any}("parent" => machine),
        "workers" => started ? _worker_section() : Any[],
        "project" => project_table,
    )
    seeds = _seed_provenance()
    seeds === nothing || (data["seeds"] = seeds)
    git_tool = started ? _PROVENANCE_GIT_TOOL[] : _path_resolved_git()
    git_tool === nothing || (data["tools"] = Dict{String, Any}[git_tool])
    source = started ? _PROVENANCE_SOURCE_SNAP[] : _resolve_source(proj)
    source === nothing || (data["source"] = source)
    sel = active_source_selection()
    deploy_rec = _deploy_record_for_provenance(active_deploy_record())
    selection = Dict{String, Any}()
    if sel !== nothing
        selection["source_kind"] = String(sel.source_kind)
        selection["deploy_root"] = sel.deploy_root
        if sel.run_id !== nothing
            selection["run_id"] = sel.run_id
        end
        if sel.content_tree_hash !== nothing
            selection["content_tree_hash"] = sel.content_tree_hash
            selection["algorithm"] = "git-sha1"
        end
        selection["work_root"] = sel.work_root
    end
    isempty(selection) || (data["selection"] = selection)
    deploy_rec !== nothing && (data["deploy"] = deploy_rec)
    return data
end

function _write_provenance_sidecar(
        output_dir::Union{Nothing, AbstractString},
        provenance::Union{Nothing, AbstractDict},
    )
    provenance === nothing && return nothing
    output_dir === nothing && return nothing
    root = strip(String(output_dir))
    isempty(root) && return nothing
    dest_dir = joinpath(canonical_local_path(root), DistSSHBase.LOCAL_STATE_DIR)
    try
        mkpath(dest_dir)
        dest = joinpath(dest_dir, "provenance.toml")
        tmp = dest * ".tmp"
        open(tmp, "w") do io
            TOML.print(io, provenance)
        end
        mv(tmp, dest; force = true)
    catch
        # best-effort only
    end
    return nothing
end

"""
    result_run_dir(result) -> Union{Nothing, String}

This run's `DISTSSH_RUN_DIR`, or `nothing` when the result has none.

`result` is a [`DriveResult`](@ref), [`GoResult`](@ref),
[`KitRunResult`](@ref), [`RideResult`](@ref), or [`KitProcess`](@ref).
Result fields and positional constructors are not API.
"""
function result_run_dir(
        result::Union{DriveResult, GoResult, KitRunResult, RideResult, KitProcess},
    )::Union{Nothing, String}
    return result.run_dir
end
public result_run_dir

"""
    result_provenance(result) -> Union{Nothing, AbstractDict}

Read `run.toml` from [`result_run_dir`](@ref). `nothing` when that
directory is unset or the file is missing.

`result` is a [`DriveResult`](@ref), [`GoResult`](@ref), or
[`KitRunResult`](@ref). A [`RideResult`](@ref) is not accepted; convert
it with [`kit_run_result`](@ref) first. A [`KitProcess`](@ref) is not
accepted; [`wait`](@ref) it first.
"""
function result_provenance(result::Union{DriveResult, GoResult, KitRunResult})
    rd = result_run_dir(result)
    rd === nothing && return nothing
    return read_kit_run_toml(rd)
end

"""String recorded under `provenance.selection`, or `nothing` when absent or blank."""
function _result_selection_string(
        result::Union{DriveResult, GoResult, KitRunResult},
        key::AbstractString,
    )::Union{Nothing, String}
    raw = result_provenance(result)
    raw isa AbstractDict || return nothing
    provenance = get(raw, "provenance", nothing)
    provenance isa AbstractDict || return nothing
    selection = get(provenance, "selection", nothing)
    if !(selection isa AbstractDict)
        selection = get(provenance, "shipped", nothing)
    end
    selection isa AbstractDict || return nothing
    value = get(selection, String(key), nothing)
    value isa AbstractString || return nothing
    text = String(value)
    return isempty(text) ? nothing : text
end

"""
    result_content_tree_hash(result) -> Union{Nothing, String}

`content_tree_hash` from this run's controller `run.toml`
(`provenance.selection`), or `nothing` when neither a ship nor an active
snapshot selection recorded one.

Schema stays 1. An absent or empty key means not recorded.
`result` is a [`DriveResult`](@ref), [`GoResult`](@ref), or
[`KitRunResult`](@ref). A [`RideResult`](@ref) goes through
[`kit_run_result`](@ref) first. A run that selected an existing completed
snapshot (without shipping in-process) may still record the hash from that
selection.

A [`SyncResult`](@ref) from `setup!` / `sync!` with `:ship_tree`, and a
[`ShipTreeResult`](@ref) from [`ship_tree!`](@ref), return the hash of that ship.
Any other [`SyncResult`](@ref) returns `nothing`.
"""
function result_content_tree_hash(
        result::Union{DriveResult, GoResult, KitRunResult},
    )::Union{Nothing, String}
    return _result_selection_string(result, "content_tree_hash")
end

function result_content_tree_hash(result::SyncResult)::Union{Nothing, String}
    return _blank_ship_string(result.content_tree_hash)
end

function result_content_tree_hash(result::ShipTreeResult)::Union{Nothing, String}
    return _blank_ship_string(result.content_tree_hash)
end
public result_content_tree_hash

"""String, or `nothing` when missing or blank."""
function _blank_ship_string(value::Union{Nothing, AbstractString})::Union{Nothing, String}
    value isa AbstractString || return nothing
    text = String(value)
    return isempty(text) ? nothing : text
end

"""
    result_remote_run_id(result) -> Union{Nothing, String}

Remote `runs/<run_id>/` id from this run's controller `run.toml`
(`provenance.selection.run_id`), or `nothing` when neither a ship nor an active
snapshot selection recorded one.

Schema stays 1. An absent or empty key means not recorded. This is not
`DISTSSH_RUN_DIR`. `result` is a [`DriveResult`](@ref), [`GoResult`](@ref),
or [`KitRunResult`](@ref). A [`RideResult`](@ref) goes through
[`kit_run_result`](@ref) first. A run that selected an existing completed
snapshot (without shipping in-process) may still record that snapshot's
`run_id`.

A [`SyncResult`](@ref) from `setup!` / `sync!` with `:ship_tree`, and a
[`ShipTreeResult`](@ref) from [`ship_tree!`](@ref), return that remote `run_id`.
Any other [`SyncResult`](@ref) returns `nothing`.
"""
function result_remote_run_id(
        result::Union{DriveResult, GoResult, KitRunResult},
    )::Union{Nothing, String}
    return _result_selection_string(result, "run_id")
end

function result_remote_run_id(result::SyncResult)::Union{Nothing, String}
    return _blank_ship_string(result.run_id)
end

function result_remote_run_id(result::ShipTreeResult)::Union{Nothing, String}
    return _blank_ship_string(result.run_id)
end
public result_remote_run_id
