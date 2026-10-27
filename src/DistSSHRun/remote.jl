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
        inner = "pkill -9 -f $(posix_quote(pattern))"
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

"""Regex that matches `pattern` and not a shell line that contains this text.

`pkill -f` on Linux matches the full command line. OpenSSH runs
`sh -c 'pkill -9 -f …'`, so a raw tag in that string can SIGKILL the
shell (exit 137) before the worker is signaled. `[d]istsshkit-job:…`
matches `distsshkit-job:…` in another argv and not the bracket text.
macOS `pkill` did not kill that shell in a local check; the bracket
still matches a process whose argv contains the raw tag.
"""
function _pkill_regex_no_self(pattern::AbstractString)::String
    s = String(pattern)
    isempty(s) && return s
    return string('[', s[1], ']', s[nextind(s, 1):end])
end

"""Remote `pkill -9 -f` for this job mark. Exit 1 (no match) is success."""
function _remote_tagged_pkill_sh(job_id::AbstractString)::String
    pattern = _pkill_regex_no_self(kit_job_pkill_pattern(job_id))
    return "pkill -9 -f $(posix_quote(pattern))"
end

"""SSH `pkill -f` for this run's job mark only (never `julia.*--worker`)."""
function _pkill_remote_tagged_workers!(host::String, job_id::AbstractString)::Bool
    if !_remote_ssh_ok(host)
        return false
    end
    inner = _remote_tagged_pkill_sh(job_id)
    try
        run(pipeline(_host_sync_remote_shell_cmd(host, inner); stdout = devnull, stderr = devnull))
    catch e
        _rethrow_missing_host_tool(e)
    end
    return true
end

# One SSH command on many hosts. `kill -INT` and tagged `pkill` share this.
# OpenSSH keeps the first value of each option, so these budgets win over
# `ssh_opts`, including a replacement `DISTRIBUTED_SSH_OPTS`.
const _SSH_PHASE_CONCURRENCY = 8
const _SSH_PHASE_ALIVE_INTERVAL = 5
const _SSH_PHASE_ALIVE_COUNT = 1

mutable struct _CmdRun
    proc::Union{Nothing, Base.Process}
    errkind::Symbol
end

_CmdRun() = _CmdRun(nothing, :none)

struct _SSHHostResult
    host::String
    proc::Union{Nothing, Base.Process}
    errkind::Symbol
end

function _ssh_phase_opts()::Vector{String}
    connect = DistSSHBase._ssh_whole_seconds(:ssh_connect, DistSSHBase._SSH_CONNECT_TIMEOUT_S)
    forced = String[
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=$connect",
        "-o", "ServerAliveInterval=$(_SSH_PHASE_ALIVE_INTERVAL)",
        "-o", "ServerAliveCountMax=$(_SSH_PHASE_ALIVE_COUNT)",
    ]
    return append!(forced, ssh_opts())
end

"""`ssh` argv for one short remote command, or the `DISTSSHKIT_TEST_SSH` double."""
function _ssh_phase_cmd(host::AbstractString, remote::AbstractString)::Cmd
    custom = _test_doubles_on() ? strip(get(ENV, "DISTSSHKIT_TEST_SSH", "")) : ""
    if !isempty(custom)
        return Cmd(vcat(_test_double_julia_argv(custom), [String(host), String(remote)]))
    end
    return _ssh_cmd(String["-n"; _ssh_phase_opts(); _ssh_host_args(String(host), String(remote))])
end

function _kill_cmd_runs!(runs::AbstractVector{_CmdRun})
    for run in runs
        proc = run.proc
        proc === nothing && continue
        try
            process_running(proc) && kill(proc, Base.SIGKILL)
        catch
        end
    end
    return nothing
end

"""
Run `cmds` with at most `ntasks` in flight. After `seconds`, SIGKILL every
local process this started, including ones that were still queued, and wait
until those tasks finish.
"""
function _run_cmds_bounded!(
        cmds::AbstractVector{Cmd},
        seconds::Real;
        ntasks::Integer = _SSH_PHASE_CONCURRENCY,
    )::Vector{_CmdRun}
    n = length(cmds)
    runs = [_CmdRun() for _ in 1:n]
    n == 0 && return runs
    stop = Ref(false)
    # `Base.Semaphore` waits on `Threads.Condition`. An `@async` task on this
    # thread does not take that permit. A channel of permits does.
    permits = Channel{Nothing}(max(1, Int(ntasks)))
    for _ in 1:max(1, Int(ntasks))
        put!(permits, nothing)
    end
    tasks = Vector{Task}(undef, n)
    for i in 1:n
        let i = i
            tasks[i] = @async begin
                try
                    take!(permits)
                catch
                    return
                end
                try
                    stop[] && return
                    proc = run(pipeline(cmds[i]; stdout = devnull, stderr = devnull); wait = false)
                    runs[i].proc = proc
                    if stop[] && process_running(proc)
                        kill(proc, Base.SIGKILL)
                    end
                    wait(proc)
                catch e
                    if e isa ProcessFailedException
                        # Non-zero exit, including SIGKILL. Callers read `exitcode`.
                    elseif e isa ArgumentError
                        runs[i].errkind = :tool
                    else
                        runs[i].errkind = :other
                    end
                finally
                    try
                        isopen(permits) && put!(permits, nothing)
                    catch
                    end
                end
            end
        end
    end
    timedwait(() -> all(istaskdone, tasks), Float64(seconds); pollint = 0.05)
    stop[] = true
    _kill_cmd_runs!(runs)
    close(permits)
    timedwait(() -> all(istaskdone, tasks), 2.0; pollint = 0.05)
    _kill_cmd_runs!(runs)
    timedwait(() -> all(istaskdone, tasks), 2.0; pollint = 0.05)
    return runs
end

"""Run one remote command per host. `seconds` is the wall-clock deadline."""
function _run_ssh_hosts!(
        host_cmds::AbstractVector{<:Pair{<:AbstractString, <:AbstractString}},
        seconds::Real;
        ntasks::Integer = _SSH_PHASE_CONCURRENCY,
    )::Vector{_SSHHostResult}
    n = length(host_cmds)
    cmds = Vector{Cmd}(undef, n)
    hosts = Vector{String}(undef, n)
    for i in eachindex(host_cmds)
        hosts[i] = String(first(host_cmds[i]))
        cmds[i] = _ssh_phase_cmd(hosts[i], last(host_cmds[i]))
    end
    runs = _run_cmds_bounded!(cmds, seconds; ntasks = ntasks)
    return [_SSHHostResult(hosts[i], runs[i].proc, runs[i].errkind) for i in eachindex(hosts)]
end

function _ssh_phase_exit_code(result::_SSHHostResult)::Union{Nothing, Int}
    result.errkind === :none || return nothing
    proc = result.proc
    proc === nothing && return nothing
    process_exited(proc) || return nothing
    # Deadline SIGKILL sets `exitcode` to 0 and `termsignal` to 9.
    # That is not a remote status.
    sig = proc.termsignal
    if sig !== nothing && Int(sig) != 0
        return nothing
    end
    code = proc.exitcode
    code === nothing && return nothing
    return Int(code)
end

# Git utilities

"""Problems when `location` is missing from HEAD or differs from HEAD."""
function _manifest_at_head_problems(
        work_tree::AbstractString,
        location::AbstractString,
    )::Vector{String}
    rel = _git_worktree_relpath(work_tree, location)
    has_head = try
        run(
            pipeline(
                _git_cmd(["-C", String(work_tree), "rev-parse", "--verify", "-q", "HEAD"]);
                stdout = devnull,
                stderr = devnull,
            )
        )
        true
    catch e
        _rethrow_missing_host_tool(e)
        false
    end
    if !has_head
        return String[
            "Manifest $rel: repository has no commit yet. git sync sends HEAD, so workers would instantiate a different resolution. Create a commit that includes the lock.",
        ]
    end
    tracked = try
        run(
            pipeline(
                _git_cmd(["-C", String(work_tree), "ls-files", "--error-unmatch", "--", rel]);
                stdout = devnull,
                stderr = devnull,
            )
        )
        true
    catch e
        _rethrow_missing_host_tool(e)
        false
    end
    tracked || return String[
        "Manifest $rel is not tracked. git sync sends HEAD, so workers would instantiate a different resolution. Commit the lock.",
    ]
    clean = try
        run(
            pipeline(
                _git_cmd(["-C", String(work_tree), "diff", "--quiet", "HEAD", "--", rel]);
                stdout = devnull,
                stderr = devnull,
            )
        )
        true
    catch e
        _rethrow_missing_host_tool(e)
        false
    end
    clean || return String[
        "Manifest $rel has uncommitted changes. git sync sends HEAD, not the working tree. Commit the lock.",
    ]
    return String[]
end

function _ensure_manifest_at_head!(
        work_tree::AbstractString,
        location::AbstractString;
        strict::Bool = false,
    )
    for msg in _manifest_at_head_problems(work_tree, location)
        strict && throw(ArgumentError(msg))
        print_warn("Warning: $msg $_SHIP_ERROR_SOON\n")
    end
    return nothing
end

"""
Throw when the lock Pkg reads, or a `[sources]` path, is outside the git
work tree of `project`.

A project file with no Manifest is an error. A directory with no project
file is not. No git work tree is not an error. A Manifest that `HEAD` would
not send (missing commit, untracked, or dirty) is an error. A `url` source
is fetched on the worker. Clone and git sync cannot carry a lock outside
the repository, or a path source that is not in `HEAD` (including a
committed symlink whose target would not arrive). Ignored or untracked
files under a path source still warn.
"""
function ensure_manifest_in_git_worktree!(project::AbstractString)
    env = resolve_pkg_env(project)
    top = git_work_tree(env.project_dir)
    top isa String || return nothing
    manifest = env.manifest
    if !(manifest isa String)
        _require_manifest!(project)
    else
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
        _ensure_manifest_at_head!(top, location; strict = true)
        # Symlink bytes reach a clone; the lock workers read is the target.
        if islink(manifest)
            _ensure_manifest_at_head!(top, target; strict = true)
        end
    end
    _ensure_path_sources_in_tree!(env, top; git = true)
    return nothing
end

"""True for a TOML parse failure from Base or the TOML stdlib."""
function _toml_parse_failed(e)::Bool
    return e isa Base.TOML.ParserError || e isa TOML.ParserError
end

"""
Warn about a lock or path source that git sync would not ship.

Skips structural errors. Those stay on the clone and git-sync path, which
throws. `--check` warns. `setup --sync` and `--pull` check the commit out
instead of stopping when the hashes already match.
"""
function _warn_git_worktree_ship!(project::AbstractString)
    env = try
        resolve_pkg_env(project)
    catch e
        _toml_parse_failed(e) || rethrow()
        print_warn(
            "Warning: could not read $(joinpath(project, "Project.toml")). " *
                "$(sprint(showerror, e))\n",
        )
        return nothing
    end
    top = git_work_tree(env.project_dir)
    top isa String || return nothing
    manifest = env.manifest
    if manifest isa String
        location = canonical_local_path(manifest)
        if _path_under_resolved(dirname(location), top)
            _ensure_manifest_at_head!(top, location)
            if islink(manifest)
                target = manifest_link_target(manifest)
                _path_under_resolved(target, top) && _ensure_manifest_at_head!(top, target)
            end
        end
    end
    root_c = canonical_local_path(top)
    for project_file in _pkg_env_project_files(env)
        sources = try
            _project_path_sources(project_file)
        catch e
            _toml_parse_failed(e) || rethrow()
            print_warn(
                "Warning: could not read path sources from $project_file. " *
                    "$(sprint(showerror, e))\n",
            )
            continue
        end
        for (name, raw) in sources
            isabspath(expanduser(raw)) && continue
            location = _resolved_source_path(project_file, raw)
            _path_under_resolved(location, root_c) || continue
            isdir(location) || continue
            _ensure_path_source_git_files!(root_c, location, name)
        end
    end
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

"""Split `find -print0` output. Paths that contain a newline are skipped."""
function _find_print0_paths(raw::AbstractString)::Vector{String}
    kept = String[]
    for part in split(raw, '\0'; keepempty = false)
        p = String(part)
        if occursin('\n', p)
            print_warn("skipping remote path that contains a newline\n")
            continue
        end
        push!(kept, p)
    end
    return kept
end

"""True when `rel` is `.git` or a file under it."""
function _collect_rel_is_git(rel::AbstractString)::Bool
    r = replace(String(rel), '\\' => '/')
    return r == ".git" || startswith(r, ".git/")
end

"""
Sentence when `collect_root` is `project_root` or an ancestor of it.

`nothing` when the root sits inside the project. A merge into the project
or a parent of it would overwrite source files, including `.git/`.
"""
function _collect_root_overlap_message(
        collect_root::AbstractString,
        project_root::AbstractString,
    )::Union{Nothing, String}
    # `abspath("dir/.")` keeps a trailing slash, so compare without it.
    dest = rstrip(canonical_local_path(collect_root), '/')
    proj = rstrip(canonical_local_path(project_root), '/')
    isempty(dest) && (dest = "/")
    isempty(proj) && (proj = "/")
    (dest == proj || startswith(proj, dest * "/")) || return nothing
    return "collect root $dest is the project root or an ancestor of it ($proj). " *
        "That would overwrite source files. Point DISTRIBUTED_COLLECT_DIRS, DISTRIBUTED_OUTPUT_DIR, or collect! at a result directory inside the project."
end

"""Print the collect-root error and return whether collection must stop."""
function _error_collect_root_overlap(
        collect_root::AbstractString,
        project_root::AbstractString,
    )::Bool
    msg = _collect_root_overlap_message(collect_root, project_root)
    msg === nothing && return false
    print_err("Error: "; bold = true)
    println_fatal(msg)
    return true
end

"""True when writing `rel` under `local_root` would leave that root.

An absolute `rel` counts: `joinpath` would drop `local_root`. An intermediate
`.` or `..`, or a symlink whose resolved path is outside `local_root`, counts.
`local_root` is resolved through symlinks before that comparison, so a root
reached via `/tmp` or another symlink does not look like an escape. Missing
path components do not.
"""
function _collect_dest_escapes_root(local_root::AbstractString, rel::AbstractString)::Bool
    normalized = Sys.iswindows() ? replace(String(rel), '\\' => '/') : String(rel)
    isabspath(normalized) && return true
    root_c = canonical_local_path(local_root)
    root = if ispath(root_c)
        try
            rstrip(canonical_local_path(realpath(root_c)), '/')
        catch
            return true
        end
    else
        rstrip(root_c, '/')
    end
    isempty(root) && (root = "/")
    cur = root
    parts = split(normalized, '/'; keepempty = false)
    for part in parts
        (part == "." || part == "..") && return true
        nxt = joinpath(cur, part)
        if islink(nxt) || isdir(nxt)
            resolved = try
                rstrip(canonical_local_path(realpath(nxt)), '/')
            catch
                return true
            end
            isempty(resolved) && (resolved = "/")
            _path_is_under(resolved, root) || return true
            cur = resolved
        else
            cur = nxt
        end
    end
    return false
end

"""First symlink under `local_root` that points outside it."""
function _collect_local_symlink_escape(local_root::AbstractString)::Union{Nothing, String}
    root = canonical_local_path(local_root)
    isdir(root) || return nothing
    for (dir, subdirs, files) in walkdir(root)
        for name in Iterators.flatten((subdirs, files))
            path = joinpath(dir, name)
            islink(path) || continue
            rel = relpath(path, root)
            _collect_dest_escapes_root(root, rel) && return rel
        end
    end
    return nothing
end

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
            _host_sync_remote_shell_cmd(hp, "find $pq -type f -print0");
            stderr = devnull,
        ),
        String,
    )
    sep = endswith(rr, "/") ? rr : (rr * "/")
    pairs = Tuple{String, String}[]
    for p in _find_print0_paths(out)
        rel = startswith(p, sep) ? p[(length(sep) + 1):end] : String(relpath(p, rr))
        isempty(rel) && continue
        startswith(rel, "..") && continue
        _collect_rel_is_git(rel) && continue
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
