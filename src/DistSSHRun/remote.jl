# Stale Distributed.jl worker cleanup (local + SSH)

"""Regex patterns for Julia `Distributed.addprocs` worker command lines."""
const JULIA_WORKER_PKILL_PATTERNS = ("julia.*--worker", "julia.*--bind-to")

"""
Kill local Julia worker processes matching [`JULIA_WORKER_PKILL_PATTERNS`](@ref).

Used by `setup --cleanup` (explicit machine-wide sweep). `drive` does not call
this: local workers are torn down with `rmprocs`. `pkill -f` may match its own
argv (patterns contain `--worker` / `--bind-to`); exit status is ignored.
"""
function _pkill_local_julia_workers!()
    for pattern in JULIA_WORKER_PKILL_PATTERNS
        try
            run(pipeline(Cmd(["pkill", "-9", "-f", pattern]); stdout = devnull, stderr = devnull))
        catch
        end
    end
    return nothing
end

"""Return whether a trivial `ssh YourHost true` succeeds."""
function _remote_ssh_ok(host::String)::Bool
    try
        run(pipeline(_host_sync_remote_shell_cmd(host, "true"); stdout = devnull, stderr = devnull))
        return true
    catch e
        _rethrow_missing_host_tool(e)
        return false
    end
end

"""
Kill stale Julia workers on `host` via SSH.

Runs one `pkill` per pattern in separate SSH sessions. A single remote shell line
`pkill -f 'julia.*--worker'; pkill …; true` is unsafe: `pkill -f` regex matches its
own argv and SIGKILLs the session before `true` (ssh exit 255, drive shows
`(unavailable)` even though the host is reachable).

Returns `false` only when SSH itself fails; `true` when the host was reached and
cleanup was attempted (including no matching processes).
"""
function _pkill_remote_julia_workers!(host::String)::Bool
    if !_remote_ssh_ok(host)
        return false
    end
    for pattern in JULIA_WORKER_PKILL_PATTERNS
        inner = "pkill -9 -f $(Base.shell_escape(pattern))"
        try
            run(pipeline(_host_sync_remote_shell_cmd(host, inner); stdout = devnull, stderr = devnull))
        catch e
            _rethrow_missing_host_tool(e)
        end
    end
    return true
end

# Visible on worker / go-slot argv so `pkill -f` can be run-scoped (see `terminate!`).
const KIT_JOB_CMDLINE_MARK::String = "distsshkit-job:"

"""`DISTSSHKIT_JOB_ID` if set and non-empty. Restricted charset for `pkill -f`."""
function _parse_kit_job_id(raw::AbstractString)::String
    s = strip(String(raw))
    isempty(s) && throw(ArgumentError("job_id must be non-empty"))
    occursin(r"^[A-Za-z0-9._:@+-]+$", s) || throw(
        ArgumentError(
            "job_id / DISTSSHKIT_JOB_ID must match [A-Za-z0-9._:@+-]+, got $(repr(raw))",
        )
    )
    return s
end

function resolved_kit_job_id()::Union{Nothing, String}
    raw = strip(get(ENV, "DISTSSHKIT_JOB_ID", ""))
    isempty(raw) && return nothing
    return _parse_kit_job_id(raw)
end

"""Julia comment whose text is [`kit_job_pkill_pattern`](@ref). Eval is a no-op."""
function kit_job_mark_comment(job_id::AbstractString)::String
    return "#" * kit_job_pkill_pattern(job_id)
end

"""Drive-worker `exeflags` word: `--eval` of [`kit_job_mark_comment`](@ref).

A comment-only `--eval` does not replace Distributed's worker bootstrap.
Do not put real code here, and do not pass this flag to a go slot — any
`--eval` makes Julia skip `programfile`. Go uses [`kit_write_job_mark_file`](@ref)
plus `-L` instead, so the user script stays the program file.
`DISTSSHKIT_JOB_ID` is process env (`addenv` / `addprocs` `env`), not `--eval`.
"""
function kit_job_eval_arg(job_id::AbstractString)::String
    return "--eval=$(kit_job_mark_comment(job_id))"
end

"""Write a no-op Julia file named [`kit_job_pkill_pattern`](@ref) under `dir`.

Go passes `-L` this path so `pkill -f` sees the tag without `--eval`.
"""
function kit_write_job_mark_file(dir::AbstractString, job_id::AbstractString)::String
    path = joinpath(dir, kit_job_pkill_pattern(job_id))
    mkpath(dir)
    write(path, kit_job_mark_comment(job_id) * "\n")
    return path
end

function kit_job_pkill_pattern(job_id::AbstractString)::String
    return string(KIT_JOB_CMDLINE_MARK, String(job_id))
end

function _drive_worker_env()
    id = resolved_kit_job_id()
    id === nothing && return Pair{String, String}[]
    return ["DISTSSHKIT_JOB_ID" => id]
end

function _drive_worker_exeflags(project::AbstractString)
    id = resolved_kit_job_id()
    id === nothing && return `--project=$project`
    return `--project=$project $(kit_job_eval_arg(id))`
end

function _pkill_pattern!(pattern::AbstractString)
    Sys.isunix() || return nothing
    try
        run(pipeline(Cmd(["pkill", "-9", "-f", String(pattern)]); stdout = devnull, stderr = devnull))
    catch
    end
    return nothing
end

"""Kill local processes whose argv contains this run's job mark. No-op if `job_id` is unset."""
function _pkill_local_tagged_workers!(job_id::AbstractString)
    _pkill_pattern!(kit_job_pkill_pattern(job_id))
    return nothing
end

"""SSH `pkill -f` for this run's job mark only (never `julia.*--worker`)."""
function _pkill_remote_tagged_workers!(host::String, job_id::AbstractString)::Bool
    if !_remote_ssh_ok(host)
        return false
    end
    inner = "pkill -9 -f $(Base.shell_escape(kit_job_pkill_pattern(job_id)))"
    try
        run(pipeline(_host_sync_remote_shell_cmd(host, inner); stdout = devnull, stderr = devnull))
    catch e
        _rethrow_missing_host_tool(e)
    end
    return true
end

# Git utilities

"""`git rev-parse --show-toplevel` for `proj_dir`, or `nothing` when it is not a work tree."""
function git_work_tree(proj_dir::AbstractString)::Union{Nothing, String}
    _host_tool_present("git") || return nothing
    resolved = canonical_local_path(proj_dir)
    try
        s = strip(
            read(
                pipeline(_git_cmd(["-C", resolved, "rev-parse", "--show-toplevel"]); stderr = devnull),
                String,
            )
        )
        return isempty(s) ? nothing : canonical_local_path(s)
    catch
        return nothing
    end
end

"""
Throw when the lock Pkg reads, or a `[sources]` path, is outside the git
work tree of `project`.

No Manifest is not an error. No git work tree is not an error. A `url`
source is fetched on the worker. Clone and git sync cannot carry a lock
outside the repository, or a path source that is not in `HEAD`
(including a committed symlink whose target would not arrive).
"""
function ensure_manifest_in_git_worktree!(project::AbstractString)
    env = resolve_pkg_env(project)
    top = git_work_tree(env.project_dir)
    top isa String || return nothing
    manifest = env.manifest
    if manifest isa String
        location = canonical_local_path(manifest)
        # The directory Pkg names, not the symlink target. A link outside the
        # work tree that points at a lock inside it is still not in the clone.
        _path_under_resolved(dirname(location), top) || throw(
            ArgumentError(
                "Manifest $location is outside the git work tree ($top). The lock would not reach a clone or git sync.",
            ),
        )
        target = manifest_link_target(manifest)
        _path_under_resolved(target, top) || throw(
            ArgumentError(
                "Manifest $location points at $target, outside the git work tree ($top). The lock would not reach a clone or git sync.",
            ),
        )
    end
    _ensure_path_sources_in_tree!(env, top; git = true)
    return nothing
end

"""Get local git commit hash (`short=nothing` → full hash, else `git rev-parse --short`)."""
function get_local_git_hash(proj_dir::AbstractString; short::Union{Nothing, Int} = nothing)::Union{Nothing, String}
    _host_tool_present("git") || return nothing
    resolved = canonical_local_path(proj_dir)
    try
        cmd = if short === nothing
            _git_cmd(["-C", resolved, "rev-parse", "HEAD"])
        else
            _git_cmd(["-C", resolved, "rev-parse", "--short=$(short)", "HEAD"])
        end
        s = strip(read(pipeline(cmd; stderr = devnull), String))
        return isempty(s) ? nothing : s
    catch
        return nothing
    end
end

"""Whether the local git working tree at `proj_dir` is clean (no uncommitted changes).

Returns `true` if clean, if `git` is missing, or if `proj_dir` is not a git work tree.
If this is a work tree but `git status` fails, returns `false` so `--require-git` /
`setup --check` still warn. This check does not block a run."""
function local_git_clean(proj_dir::AbstractString)::Bool
    _host_tool_present("git") || return true
    resolved = canonical_local_path(proj_dir)
    inside = try
        strip(
            read(
                pipeline(
                    _git_cmd(["-C", resolved, "rev-parse", "--is-inside-work-tree"]);
                    stderr = devnull,
                ), String
            )
        )
    catch
        return true
    end
    inside == "true" || return true
    try
        result = read(pipeline(_git_cmd(["-C", resolved, "status", "--porcelain"]); stderr = devnull), String)
        return isempty(strip(result))
    catch
        return false
    end
end


"""Get total memory (GB) and CPU cores for localhost."""
function get_local_resources()
    total_gb = Sys.total_memory() / 1024^3
    nproc = try
        s = strip(read(pipeline(`sysctl -n hw.ncpu`, stderr = devnull), String))
        isempty(s) ? Sys.CPU_THREADS : parse(Int, s)
    catch
        Sys.CPU_THREADS
    end
    return (total_gb = total_gb, nproc = nproc)
end

# Remote path resolution & result collection

"""
List all files under `remote_root` on `host` recursively via SSH `find`, returning
`(remote_abs_path, relative_path)` pairs (relative to `remote_root`).

Tilde roots (`~/…`) are expanded **on the remote** before `find`. Matching must
not use local `relpath`/`abspath` against a tilde base (that expands `~` to the
kit parent home and yields bogus `../…` relatives).
"""
function collect_tree_remote_files_ssh(host::AbstractString, remote_root::AbstractString)::Vector{Tuple{String, String}}
    hp = String(host)
    rr = ensure_remote_abs_path(hp, remote_root)
    rr === nothing && return Tuple{String, String}[]
    rr = rr::String
    pq = _remote_shell_path_word(rr)
    out = read(
        pipeline(
            _host_sync_remote_shell_cmd(hp, "find $pq -type f -print");
            stderr = devnull,
        ),
        String,
    )
    sep = endswith(rr, "/") ? rr : (rr * "/")
    pairs = Tuple{String, String}[]
    for line in split(out, '\n')
        p = String(strip(line))
        isempty(p) && continue
        rel = startswith(p, sep) ? p[(length(sep) + 1):end] : String(relpath(p, rr))
        isempty(rel) && continue
        startswith(rel, "..") && continue
        push!(pairs, (p, rel))
    end
    return pairs
end


"""
Local absolute directories used for per-run sentinel placement and post-run rsync from SSH workers.

If `ENV["DISTRIBUTED_COLLECT_DIRS"]` is non-empty: colon-separated list (same convention as POSIX `PATH`).
Each token is `canonical_local_path(token)` when absolute, otherwise `canonical_local_path(joinpath(project_root, token))`.
Empty tokens are skipped; duplicates removed (first occurrence order preserved).

If unset or blank after trimming: a single root from [`resolve_drive_output_dir`](@ref)
(`DISTRIBUTED_OUTPUT_DIR`, else `{script_dir}/.distsshkit/drive` kind root).

Scripts should set `DISTRIBUTED_COLLECT_DIRS` to every tree that may receive new files on workers during the run
(e.g. sweep output plus figures). Logs may stay under `DISTRIBUTED_OUTPUT_DIR` only; omit that path here if logs
should not be rsync'd.
"""
function distributed_collect_root_dirs(
        script_dir::AbstractString,
        project_root::AbstractString,
    )::Vector{String}
    spec = String(strip(get(ENV, "DISTRIBUTED_COLLECT_DIRS", "")))
    repo = canonical_local_path(project_root)
    if !isempty(spec)
        out = String[]
        for chunk in split(spec, ':')
            p = String(strip(String(chunk)))
            isempty(p) && continue
            raw = String(expanduser(p))
            ap = canonical_local_path(isabspath(raw) ? raw : joinpath(repo, raw))
            push!(out, ap)
        end
        seen = Set{String}()
        uniq = String[]
        for p in out
            p in seen && continue
            push!(seen, p)
            push!(uniq, p)
        end
        if !isempty(uniq)
            return uniq
        end
    end
    return String[resolve_drive_output_dir(script_dir)]
end
