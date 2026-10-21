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
const _PROVENANCE_GO = Pair{String, String}[]

const _GO_SLOT_PROVENANCE_NAME = "provenance-slot.toml"
const _GO_SLOT_LOADER_NAME = "provenance-slot.jl"

# Same fields as `_process_snapshot_expr`. A go slot has no DistSSHRun, so `-L` runs this text.
const _GO_SLOT_LOADER_SRC = """
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
        dir = get(ENV, "DISTRIBUTED_OUTPUT_DIR", pwd())
        dest = joinpath(dir, ".distsshkit")
        mkpath(dest)
        open(joinpath(dest, "provenance-slot.toml"), "w") do io
            TOML.print(io, snap)
        end
    end
catch
end
"""

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
    commit = "DISTSSHKIT_SOURCE_COMMIT",
    dirty = "DISTSSHKIT_SOURCE_DIRTY",
    diff_sha256 = "DISTSSHKIT_SOURCE_DIFF_SHA256",
    captured = "DISTSSHKIT_SOURCE_CAPTURED",
    untracked = "DISTSSHKIT_SOURCE_UNTRACKED",
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
)

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
            Dict{String, String}(
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
    _PROVENANCE_PROJECT_SNAP[] = _project_provenance(proj)
    _PROVENANCE_SOURCE_SNAP[] = _resolve_source(proj)
    _PROVENANCE_AT_START[] = true
    return nothing
end

"""Write the go-slot `-L` file. `nothing` when the directory cannot be written."""
function write_go_slot_loader(slot_dir::AbstractString)::Union{Nothing, String}
    return try
        dest = joinpath(slot_dir, ".distsshkit")
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
    path = joinpath(String(slot_dir), ".distsshkit", _GO_SLOT_PROVENANCE_NAME)
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

function _sha256_hex(bytes::AbstractVector{UInt8})::String
    return SHA.bytes2hex(SHA.sha256(bytes))
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
    proc.exitcode == 0 || return nothing
    return SHA.bytes2hex(SHA.digest!(ctx))
end

function _snapshot_dict(raw)::Dict{String, String}
    raw isa AbstractDict || return Dict{String, String}("error" => "snapshot was not a dict")
    out = Dict{String, String}()
    for (k, v) in raw
        out[string(k)] = string(v)
    end
    for key in _SNAP_KEYS
        haskey(out, key) || return Dict{String, String}("error" => "incomplete snapshot")
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
    return join((snap[k] for k in _SNAP_KEYS), '\0')
end

function _group_body(snap::Dict{String, String})::Dict{String, Any}
    if haskey(snap, "error")
        return Dict{String, Any}("error" => snap["error"], "n" => 1)
    end
    return Dict{String, Any}(
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

function _project_manifest_path(project::AbstractString)::String
    fallback = joinpath(project, "Manifest.toml")
    pfile = joinpath(project, "Project.toml")
    isfile(pfile) || return fallback
    found = Base.project_file_manifest_path(pfile)
    return found isa AbstractString ? String(found) : fallback
end

function _project_provenance(project::AbstractString)::Dict{String, Any}
    manifest = _project_manifest_path(project)
    isfile(manifest) || return Dict{String, Any}("manifest" => "absent")
    out = Dict{String, Any}("manifest" => _sha256_hex(read(manifest)))
    parsed = try
        TOML.parsefile(manifest)
    catch
        nothing
    end
    if parsed isa AbstractDict && haskey(parsed, "julia_version")
        out["julia_version"] = string(parsed["julia_version"])
    end
    return out
end

function _git_capture_bytes(cmd::Cmd)::Union{Nothing, Vector{UInt8}}
    out = IOBuffer()
    ok = try
        proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = devnull))
        proc.exitcode == 0
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

"""Work tree at `project`, or `nothing` when git is missing or this is not a work tree.

`.distsshkit/` and `.distsshqueue/` are not uncommitted changes. DistSSHQueue calls this
once that release is available. Until then it keeps a copy of the same rule.
"""
function git_source_snapshot(project::AbstractString)::Union{Nothing, Dict{String, Any}}
    src = _git_source(project)
    src === nothing && return nothing
    out = Dict{String, Any}()
    for (k, v) in src
        String(k) == "captured" && continue
        out[String(k)] = v
    end
    return out
end

"""Kit and Queue write these directories inside the caller's tree. They are not the caller's edits."""
function _git_status_is_kit(path::AbstractString)::Bool
    for name in (".distsshkit", ".distsshqueue")
        path == name && return true
        startswith(path, name * "/") && return true
        occursin("/" * name * "/", path) && return true
    end
    return false
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
    for key in ("commit", "diff_sha256", "captured")
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
            :diff_sha256 => _PROVENANCE_SOURCE_ENV.diff_sha256,
            :captured => _PROVENANCE_SOURCE_ENV.captured,
            :untracked => _PROVENANCE_SOURCE_ENV.untracked,
        )
        haskey(ENV, envk) && (raw[String(field)] = ENV[envk])
    end
    built = _source_from_user(raw)
    return isempty(built) ? nothing : built
end

"""Drop inherited `DISTSSHKIT_SOURCE_*` keys that this explicit `source` did not set.

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
    return _git_source(project)
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
        "julia" => Dict{String, Any}("parent" => julia),
        "machine" => Dict{String, Any}("parent" => machine),
        "workers" => started ? _worker_section() : Any[],
        "project" => project_table,
    )
    source = started ? _PROVENANCE_SOURCE_SNAP[] : _resolve_source(proj)
    source === nothing || (data["source"] = source)
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
    dest_dir = joinpath(canonical_local_path(root), ".distsshkit")
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
