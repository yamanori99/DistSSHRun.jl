# Rsync local project tree to SSH hosts (shared by `setup --rsync` and `sync!`).


function _host_sync_rsync_transport()::String
    custom = _test_doubles_on() ? strip(get(ENV, "DISTSSHKIT_TEST_SSH", "")) : ""
    if !isempty(custom)
        return join(_test_double_julia_argv(custom), " ")
    end
    return join(Base.shell_escape.([_ssh_exe(); ssh_opts()]), " ")
end

function _host_sync_rsync_argv()::Vector{String}
    custom = _test_doubles_on() ? strip(get(ENV, "DISTSSHKIT_TEST_RSYNC", "")) : ""
    if !isempty(custom)
        path = abspath(custom)
        # `.jl` doubles spawn Julia; prefer `.sh` so collect tests do not nest a
        # second compiler (GHA OOM).
        endswith(path, ".jl") && return _test_double_julia_argv(path)
        return ["sh", path]
    end
    return [_host_tool_exe("rsync")]
end

"""Run rsync with `--files-from` via a temp list, not `stdin`.

Julia 1.14 `pipeline(; stdin=buf)` waits for the write and throws `EPIPE` if the
child exits without reading stdin (fake rsync, or rsync dying on argv). A list
file is the same rsync contract without that pipe.
"""
function _run_rsync_files_from(
        rsync_bin::Vector{String},
        opts::Vector{String},
        src::AbstractString,
        dest::AbstractString,
        files::Vector{String};
        stderr = stderr,
    )
    mktemp() do path, io
        for rel in files
            println(io, rel)
        end
        close(io)
        cmd = Cmd(vcat(rsync_bin, opts, ["--files-from=$path", String(src), String(dest)]))
        run(pipeline(cmd; stderr = stderr))
    end
    return nothing
end

function _join_send_rel(prefix::AbstractString, rel::AbstractString)::String
    p = String(prefix)
    r = String(rel)
    isempty(p) && return r
    return p * "/" * r
end

function _send_rel_excluded(rel::AbstractString)::Bool
    r = replace(String(rel), '\\' => '/')
    parts = split(r, '/')
    return ".git" in parts || ".distsshkit" in parts
end

"""`git ls-files -z` records. Throws when git fails (after missing-tool checks)."""
function _git_ls_files_z(dir::AbstractString, args::Vector{String})::Vector{String}
    err_buf = IOBuffer()
    try
        raw = read(
            pipeline(_git_cmd(vcat(["-C", String(dir), "ls-files", "-z"], args)); stderr = err_buf),
            String,
        )
        return String[s for s in split(raw, '\0') if !isempty(s)]
    catch e
        _rethrow_missing_host_tool(e)
        detail = strip(String(take!(err_buf)))
        msg = isempty(detail) ? "git ls-files failed in $dir" : "git ls-files failed in $dir:\n$detail"
        error(msg)
    end
end

function _git_submodule_paths(dir::AbstractString)::Set{String}
    found = Set{String}()
    for rec in _git_ls_files_z(dir, ["-s"])
        startswith(rec, "160000 ") || continue
        tab = findfirst('\t', rec)
        tab === nothing && continue
        push!(found, rec[(tab + 1):end])
    end
    return found
end

function _reject_newline_send_path(rel::AbstractString)
    occursin('\n', rel) || return nothing
    throw(
        ArgumentError(
            "cannot rsync a path that contains a newline ($(repr(rel))). Rename it and retry.",
        )
    )
end

"""
True when `rel` itself is ignored by a directory `.gitignore` (no trailing slash).

`output/*` ignores contents but not `output`, so the directory is still sent.
`build/` ignores the directory itself.
"""
function _git_path_ignored(dir::AbstractString, rel::AbstractString)::Bool
    r = replace(String(rel), '\\' => '/')
    endswith(r, "/") && (r = r[1:(end - 1)])
    isempty(r) && return false
    err_buf = IOBuffer()
    try
        # Exit 0 → ignored. Exit 1 → not ignored.
        run(
            pipeline(
                _git_cmd(["-C", String(dir), "check-ignore", "-q", "--", r]);
                stdout = devnull,
                stderr = err_buf,
            )
        )
        return true
    catch e
        _rethrow_missing_host_tool(e)
        return false
    end
end

function _push_send_rel!(out::Vector{String}, prefix::AbstractString, rel::AbstractString)
    listed = _join_send_rel(prefix, rel)
    _send_rel_excluded(listed) && return nothing
    _reject_newline_send_path(listed)
    push!(out, listed)
    return nothing
end

"""
Add files and directories under `dir` (no app `.gitignore`). Skips `.git` /
`.distsshkit`. Directory symlinks are listed as files (rsync `-a` sends the link).

Uses an explicit stack (not `walkdir` + mutating `dirs`): Julia's `walkdir`
Channel may buffer, so mutating `dirs` does not reliably prune descent.
"""
function _walk_send_files!(out::Vector{String}, dir::AbstractString, prefix::AbstractString)
    isdir(dir) || return nothing
    stack = String[String(dir)]
    while !isempty(stack)
        cur = pop!(stack)
        rel_dir = relpath(cur, dir)
        if rel_dir != "."
            _push_send_rel!(out, prefix, rel_dir)
        end
        for name in readdir(cur; join = false, sort = false)
            name == ".git" && continue
            name == ".distsshkit" && continue
            child = joinpath(cur, name)
            if islink(child)
                rel = rel_dir == "." ? name : joinpath(rel_dir, name)
                _push_send_rel!(out, prefix, rel)
                continue
            end
            if isdir(child)
                push!(stack, child)
                continue
            end
            rel = rel_dir == "." ? name : joinpath(rel_dir, name)
            _push_send_rel!(out, prefix, rel)
        end
    end
    return nothing
end

"""
Directories that still exist after `.gitignore` filtering, for `--files-from`
(creates them on the remote without recursing into their contents).
"""
function _append_gitignore_dirs!(
        out::Vector{String},
        dir::AbstractString,
        prefix::AbstractString,
    )
    isdir(dir) || return nothing
    stack = String[String(dir)]
    while !isempty(stack)
        cur = pop!(stack)
        rel_dir = relpath(cur, dir)
        if rel_dir != "."
            _git_path_ignored(dir, rel_dir) && continue
            _push_send_rel!(out, prefix, rel_dir)
        end
        for name in readdir(cur; join = false, sort = false)
            name == ".git" && continue
            name == ".distsshkit" && continue
            child = joinpath(cur, name)
            islink(child) && continue
            isdir(child) || continue
            isdir(joinpath(child, ".git")) && continue
            rel = rel_dir == "." ? name : joinpath(rel_dir, name)
            _git_path_ignored(dir, rel) && continue
            push!(stack, child)
        end
    end
    return nothing
end

"""
Append the git send list for `dir` (paths relative to `dir`, then prefixed).

`--cached` keeps tracked files even when they match `.gitignore`. `--others
--exclude-per-directory=.gitignore` applies negation from each directory's
`.gitignore` only (not `.git/info/exclude` or `core.excludesFile`). A trailing
slash or a gitlink (mode 160000) is expanded in that directory. Directories that
are not themselves ignored are listed so `--files-from` still creates them when
empty (`output/*` keeps `output/`; `build/` does not).
"""
function _git_worktree_file_list!(
        out::Vector{String},
        dir::AbstractString,
        prefix::AbstractString,
        seen::Set{String},
    )
    c = canonical_local_path(dir)
    c in seen && return nothing
    push!(seen, c)
    if git_work_tree(dir) === nothing
        _walk_send_files!(out, dir, prefix)
        return nothing
    end
    subs = _git_submodule_paths(dir)
    for rel in _git_ls_files_z(
            dir,
            ["--cached", "--others", "--exclude-per-directory=.gitignore"],
        )
        bare = endswith(rel, "/") ? rel[1:(end - 1)] : rel
        if endswith(rel, "/") || bare in subs
            _git_worktree_file_list!(out, joinpath(dir, bare), _join_send_rel(prefix, bare), seen)
            continue
        end
        full_path = joinpath(dir, rel)
        (isfile(full_path) || islink(full_path)) || continue
        _push_send_rel!(out, prefix, rel)
    end
    _append_gitignore_dirs!(out, dir, prefix)
    return nothing
end

function _rsync_path_source_dirs(env, root::AbstractString)::Vector{String}
    root_c = canonical_local_path(root)
    found = String[]
    for project_file in _pkg_env_project_files(env)
        for (_, raw) in _project_path_sources(project_file)
            isabspath(expanduser(raw)) && continue
            loc = canonical_local_path(_resolved_source_path(project_file, raw))
            loc == root_c && continue
            isdir(loc) || continue
            _path_is_under(loc, root_c) || continue
            push!(found, loc)
        end
    end
    return unique(found)
end

function _independent_git_repo(dir::AbstractString)::Bool
    top = git_work_tree(dir)
    top isa String || return false
    d = canonical_local_path(dir)
    top == d && return true
    # `git rev-parse` may spell `/private/var` while `abspath` still has `/var`.
    (ispath(top) && ispath(d)) || return false
    return canonical_local_path(realpath(top)) == canonical_local_path(realpath(d))
end

"""
Files to rsync, relative to `local_root`.

`nothing` when `local_root` is outside a git work tree: the caller keeps
rsync's per-directory `.gitignore` filter (negation is not applied).
An empty list throws `ArgumentError`.
"""
function _rsync_send_list(local_root::AbstractString, env)::Union{Nothing, Vector{String}}
    root = canonical_local_path(local_root)
    git_work_tree(root) === nothing && return nothing
    sources = _rsync_path_source_dirs(env, root)
    source_rels = String[relpath(s, root) for s in sources]
    out = String[]
    _git_worktree_file_list!(out, root, "", Set{String}())
    function _under_source(rel::AbstractString)::Bool
        r = replace(String(rel), '\\' => '/')
        for src in source_rels
            s = replace(src, '\\' => '/')
            (r == s || startswith(r, s * "/")) && return true
        end
        return false
    end
    filtered = String[rel for rel in out if !_under_source(rel)]
    for (src, rel_src) in zip(sources, source_rels)
        if _independent_git_repo(src)
            _git_worktree_file_list!(filtered, src, rel_src, Set{String}())
        else
            _walk_send_files!(filtered, src, rel_src)
        end
    end
    unique!(filtered)
    isempty(filtered) && throw(ArgumentError("nothing to send from $root"))
    return filtered
end


"""Remote shell snippet classifying `remote_path` as MISSING / EMPTY / NONEMPTY."""
function _remote_dest_status_script(remote_path::AbstractString)::String
    pq = _remote_shell_path_word(remote_path)
    # Leading marker keeps test doubles and parsers stable.
    return string(
        "echo DISTSSHKIT_DEST_STATUS; ",
        "if [ ! -e $pq ]; then echo MISSING; ",
        "elif [ ! -d $pq ]; then echo NONEMPTY; ",
        "elif [ -z \"\$(ls -A $pq 2>/dev/null)\" ]; then echo EMPTY; ",
        "else echo NONEMPTY; fi",
    )
end

"""
Classify `remote_path` on `host`: `:missing`, `:empty`, or `:nonempty`.

Uses `_host_sync_remote_shell_cmd` (honors `DISTSSHKIT_TEST_SSH`).
On SSH/script failure, returns `:nonempty` (fail closed — refuse overwrite).
"""
function remote_dest_status(host::String, remote_path::AbstractString)::Symbol
    try
        result = read(
            pipeline(
                _host_sync_remote_shell_cmd(host, _remote_dest_status_script(remote_path));
                stderr = devnull,
            ),
            String,
        )
        for line in eachline(IOBuffer(result))
            s = strip(line)
            s == "MISSING" && return :missing
            s == "EMPTY" && return :empty
            s == "NONEMPTY" && return :nonempty
        end
        return :nonempty
    catch
        return :nonempty
    end
end

function remote_dest_busy_message(host::AbstractString, remote_path::AbstractString)::String
    return string(
        "remote path already exists on ",
        host,
        ": ",
        remote_path,
        " (refusing to overwrite). ",
        "Delete it first, e.g.: julia --project=. -m DistSSHKit setup --delete ",
        setup_cli_host_token(host),
    )
end

function _remote_dir_exists(host::String, remote_path::String)::Bool
    st = remote_dest_status(host, remote_path)
    return st === :empty || st === :nonempty
end

function _ensure_remote_dir(host::String, remote_path::String)::Bool
    pq = _remote_shell_path_word(remote_path)
    try
        run(
            pipeline(
                _host_sync_remote_shell_cmd(host, "mkdir -p $pq");
                stderr = devnull,
                stdout = devnull,
            ),
        )
        return true
    catch e
        _rethrow_missing_host_tool(e)
        return false
    end
end

function _print_rsync_safety_banner!(
        local_root::AbstractString,
        remote_path::AbstractString,
        hosts::Vector{String},
        path_anchor::AbstractString,
    )
    # Consent text: always on the terminal (same gate as `kit_confirm`).
    print_warn("  This bypasses git entirely: no commit, no push/pull, no hash check.\n")
    println_fatal("  Local and remote git commits will likely disagree afterwards.")
    println_fatal("  That is fine: `drive` does not require git parity by default.")
    println_fatal("  Use `drive --require-git` only with git-managed remotes.")
    println_fatal("  Prefer `setup --sync` when you need the git-commit reproducibility guarantee.")
    println_fatal()
    print_warn("  Safety: refuses if the remote path already has any files.\n")
    println_fatal("  To replace an existing tree, run `setup --delete` first, then `--rsync`.")
    if git_work_tree(local_root) isa String
        println_fatal("  Sends the git file list from each directory's `.gitignore` (negation applies). Excludes `.git/` and `.distsshkit/`. Directories are still created when empty.")
    else
        println_fatal("  Applies `.gitignore` exclude lines with rsync's per-directory filter. Negation patterns are not applied. Excludes `.git/` and `.distsshkit/`.")
    end
    println_fatal()
    println_fatal("  Local project: $(display_path(local_root, path_anchor))")
    println_fatal("  Remote path: $remote_path")
    println_fatal("  Hosts: $(join(hosts, ", "))")
    println_fatal()
    return nothing
end

"""
Run rsync for one host. Returns
`(; status=:ok|:busy|:mkdir_fail, message, dir_created)`.
Throws on rsync command failure after setup.
"""
function _rsync_one_host!(
        host::String,
        local_root::AbstractString,
        remote_path::AbstractString,
        ssh_cmd_str::String,
        send_list::Union{Nothing, Vector{String}},
    )
    st = remote_dest_status(host, remote_path)
    if st === :nonempty
        return (;
            status = :busy,
            message = remote_dest_busy_message(host, remote_path),
            dir_created = false,
        )
    end
    dir_created = false
    if st === :missing
        if !_ensure_remote_dir(host, remote_path)
            return (;
                status = :mkdir_fail,
                message = "could not create remote directory",
                dir_created = false,
            )
        end
        dir_created = true
    end
    # The destination is refused unless it is missing or empty, so --delete would remove nothing.
    dest = string(host, ":", remote_path, "/")
    if send_list === nothing
        rsync_cmd = Cmd(
            vcat(
                _host_sync_rsync_argv(),
                String[
                    "-az",
                    "-e",
                    ssh_cmd_str,
                    "--exclude",
                    ".git/",
                    "--exclude",
                    ".distsshkit/",
                    "--filter",
                    ":- .gitignore",
                    local_root * "/",
                    dest,
                ],
            ),
        )
        run(pipeline(rsync_cmd; stderr = stderr))
    else
        _run_rsync_files_from(
            _host_sync_rsync_argv(),
            String[
                "-az",
                "-e",
                ssh_cmd_str,
                "--exclude",
                ".git/",
                "--exclude",
                ".distsshkit/",
            ],
            local_root * "/",
            dest,
            send_list::Vector{String},
        )
    end
    return (; status = :ok, message = "", dir_created = dir_created)
end

"""
    rsync_project_to_hosts!(
        hosts, local_root, remote_path;
        confirm=true, report=false, path_anchor=local_root,
    )

Rsync `local_root/` to `remote_path` on each SSH host. Returns
`(cancelled, succeeded, failed, host_results)`.

Refuses hosts where `remote_path` already has any entries (safety). Use
`setup --delete` first to replace an existing tree. Missing or empty
directories are created/filled.

When `confirm=true`, prints warnings and requires typing `rsync` (unless
[`kit_noninteractive`](@ref) / `--yes` is active — then confirmation is skipped,
but the nonempty-path refusal still applies).
"""
function rsync_project_to_hosts!(
        hosts::Vector{String},
        local_root::AbstractString,
        remote_path::AbstractString;
        confirm::Bool = true,
        report::Bool = false,
        path_anchor::AbstractString = local_root,
    )::NamedTuple
    given = canonical_local_path(local_root)
    env0 = resolve_pkg_env(given)
    send_list = _rsync_send_list(given, env0)
    shipped = ensure_manifest_ships!(given; send_list = send_list)
    local_root = shipped.env_dir
    raw_anchor = canonical_local_path(path_anchor)
    anchor = raw_anchor == given ? local_root : raw_anchor
    remote_path = String(remote_path)

    if confirm && !kit_noninteractive()
        cancelled = let anchor = anchor
            with_kit_progress_suspended() do
                _print_rsync_safety_banner!(local_root, remote_path, hosts, anchor)
                if !kit_confirm("Type 'rsync' to confirm: "; keyword = "rsync")
                    println_fatal("Cancelled.")
                    return true
                end
                println_fatal()
                return false
            end
        end
        cancelled && return (
            cancelled = true,
            succeeded = 0,
            failed = 0,
            host_results = HostResult[],
        )
    end

    ssh_cmd_str = _host_sync_rsync_transport()
    n_hosts = length(hosts)
    host_results = Vector{HostResult}(undef, n_hosts)
    jobs = kit_host_jobs()
    sequential_spin = report && jobs == 1

    function _rsync_host_result(host::String)::HostResult
        dir_created = false
        try
            outcome = if sequential_spin
                kit_spin!("  $host: ") do
                    _rsync_one_host!(host, local_root, remote_path, ssh_cmd_str, send_list)
                end
            else
                _rsync_one_host!(host, local_root, remote_path, ssh_cmd_str, send_list)
            end
            if outcome.status === :busy || outcome.status === :mkdir_fail
                return HostResult(host, false, outcome.message)
            end
            dir_created = outcome.dir_created
            return HostResult(
                host,
                true,
                dir_created ? "rsync ok (created remote dir)" : "rsync ok",
            )
        catch e
            msg = sprint(showerror, e)
            if dir_created
                msg = "rsync failed after creating directory: " * msg
            end
            return HostResult(host, false, msg)
        end
    end

    map_host_jobs(hosts) do i, host
        host_results[i] = _setup_host_call!(host) do
            _rsync_host_result(host)
        end
    end

    succeeded = 0
    failed = 0
    for hr in host_results
        if hr.ok
            succeeded += 1
        else
            failed += 1
        end
        if report && !sequential_spin
            kit_print("  $(hr.host): ")
            if hr.ok
                print_ok("✓")
                kit_println()
            else
                print_err("✗ $(hr.message)")
                println()
            end
        elseif report && sequential_spin && !hr.ok
            print_err("✗ $(hr.message)")
            println()
        elseif report && sequential_spin && hr.ok
            print_ok("✓")
            kit_println()
        end
    end

    if confirm
        kit_println()
        writeln_both("Reminder: local/remote git commits are not tracked by this operation.")
        writeln_both(
            "`drive` runs without git parity by default; use --require-git only on git remotes.",
        )
    end

    return (
        cancelled = false,
        succeeded = succeeded,
        failed = failed,
        host_results = host_results,
    )
end
