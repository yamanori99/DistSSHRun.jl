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

"""Flags for remote→local rsync that is still rsync (cache pull).

Collect and go slot pull use Tar. `--safe-links` remains on this rsync path.
"""
function _pull_rsync_opts(transport::AbstractString)::Vector{String}
    return String["-az", "--safe-links", "-e", String(transport)]
end

const _TAR_PULL_ALL = "using Tar; Tar.create(ARGS[1], stdout)"

# NUL-separated relative paths arrive on stdin. Parents of a wanted path stay
# so Tar can reach the file. Unwanted siblings are left out of the archive.
const _TAR_PULL_FILTERED = """
using Tar
root = ARGS[1]
wanted = Set{String}()
for part in split(read(stdin, String), '\\0')
    isempty(part) || push!(wanted, part)
end
function keep(path)
    rel = replace(relpath(path, root), '\\\\' => '/')
    rel == "." && return true
    rel in wanted && return true
    for w in wanted
        startswith(w, rel * "/") && return true
    end
    return false
end
Tar.create(keep, root, stdout)
"""

"""Remote Julia that writes a Tar of `remote_dir` to stdout.

`filtered` reads the relative paths from stdin. File modes are not in the
archive: Tar stores `0644`, or `0755` when the file is executable.
"""
function _remote_tar_create_sh(
        julia_bin::AbstractString,
        remote_dir::AbstractString;
        filtered::Bool = false,
    )::String
    jb = _remote_julia_path_sh(julia_bin)
    q = _remote_shell_path_word(remote_dir)
    body = posix_quote(filtered ? _TAR_PULL_FILTERED : _TAR_PULL_ALL)
    return "$jb --startup-file=no -e $body -- $q"
end

"""Pinned remote Julia for a Tar pull. `spec` is `--julia` or auto-detect."""
function _pull_remote_julia(
        host::AbstractString,
        spec::Union{Nothing, AbstractString},
    )::String
    found = pin_remote_julia(String(host), spec)
    found === nothing && throw(
        ArgumentError("Julia not found on remote host $(host) (auto-detect failed)"),
    )
    return found
end

"""Reject a symlink whose chain leaves `root`. Do not follow a hop that is outside."""
function _assert_extracted_symlink_under!(path::AbstractString, root::AbstractString)
    root = canonical_local_path(root)
    rel = relpath(canonical_local_path(path), root)
    sep = Base.Filesystem.path_separator
    (rel == ".." || startswith(rel, ".." * sep)) &&
        throw(ArgumentError("tar pull refuses escaping symlink $path"))
    pending = rel
    hops = 0
    seen = Set{String}()
    while true
        parts = split(pending, sep)
        current = root
        restarted = false
        for (i, part) in enumerate(parts)
            (isempty(part) || part == ".") && continue
            part == ".." && throw(ArgumentError("tar pull refuses escaping symlink $path"))
            nxt = joinpath(current, String(part))
            islink(nxt) || (current = nxt; continue)
            hops += 1
            hops > 40 && throw(ArgumentError("tar pull refuses symlink loop $path"))
            nxt in seen && throw(ArgumentError("tar pull refuses symlink loop $path"))
            push!(seen, nxt)
            target = readlink(nxt)
            resolved = isabspath(target) ? normpath(target) : normpath(joinpath(dirname(nxt), target))
            _path_is_under(resolved, root) ||
                throw(ArgumentError("tar pull refuses escaping symlink $path"))
            rest = String[String(later) for later in parts[(i + 1):end]]
            newrel = relpath(canonical_local_path(resolved), root)
            pending = isempty(rest) ? newrel : joinpath(newrel, rest...)
            restarted = true
            break
        end
        restarted || return nothing
    end
end

function _finish_extracted_tree!(dest::AbstractString; allow_external_symlinks::Bool = false)
    root = canonical_local_path(dest)
    for (dir, dirs, files) in walkdir(root)
        for name in dirs
            path = joinpath(dir, name)
            islink(path) || continue
            allow_external_symlinks && continue
            _assert_extracted_symlink_under!(path, root)
        end
        for name in files
            path = joinpath(dir, name)
            if islink(path)
                allow_external_symlinks || _assert_extracted_symlink_under!(path, root)
            else
                touch(path)
            end
        end
    end
    return nothing
end

function _extracted_rel_paths(root::AbstractString)::Vector{String}
    rels = String[]
    for (dir, dirs, files) in walkdir(root)
        for name in dirs
            path = joinpath(dir, name)
            islink(path) && push!(rels, relpath(path, root))
        end
        if dir != root && isempty(dirs) && isempty(files) && !islink(dir)
            push!(rels, relpath(dir, root))
        end
        for name in files
            push!(rels, relpath(joinpath(dir, name), root))
        end
    end
    return rels
end

function _collected_is_real_dir(path::AbstractString)::Bool
    return isdir(path) && !islink(path)
end

"""Copy one extracted path. A file must not replace a local directory."""
function _copy_collected_path!(src::AbstractString, dest::AbstractString)
    if ispath(dest) || islink(dest)
        src_dir = _collected_is_real_dir(src)
        dest_dir = _collected_is_real_dir(dest)
        if src_dir != dest_dir
            throw(
                ArgumentError(
                    "collect refuses to replace a local $(dest_dir ? "directory" : "file") with a remote $(src_dir ? "directory" : "file"): $dest",
                ),
            )
        end
    end
    if _collected_is_real_dir(src)
        mkpath(dest)
        return nothing
    end
    parent = dirname(dest)
    parent == dest || mkpath(parent)
    cp(src, dest; force = true, follow_symlinks = false)
    islink(dest) || touch(dest)
    return nothing
end

function _extract_remote_tar!(
        host::AbstractString,
        remote_dir::AbstractString,
        dest::AbstractString;
        julia_bin::AbstractString,
        rels::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
        allow_external_symlinks::Bool = false,
    )
    mkpath(dest)
    isempty(readdir(dest)) || throw(ArgumentError("tar extract dest is not empty: $dest"))
    blob_dir = mktempdir()
    blob = joinpath(blob_dir, "pull.tar")
    try
        filtered = rels !== nothing
        inner = _remote_tar_create_sh(julia_bin, remote_dir; filtered = filtered)
        err = IOBuffer()
        cmd = _host_sync_remote_shell_cmd(String(host), inner; forward_stdin = filtered)
        list = IOBuffer()
        if filtered
            for rel in rels
                occursin('\0', rel) && throw(ArgumentError("collect path contains NUL: $(repr(rel))"))
                write(list, String(rel), '\0')
            end
            seekstart(list)
        end
        proc = run(
            pipeline(ignorestatus(cmd); stdin = filtered ? list : devnull, stdout = blob, stderr = err);
            wait = true,
        )
        proc.exitcode == 0 || throw(
            ArgumentError("tar pull failed on $(host): $(strip(String(take!(err))))"),
        )
        Tar.extract(blob, dest)
        _finish_extracted_tree!(dest; allow_external_symlinks = allow_external_symlinks)
    finally
        rm(blob_dir; force = true, recursive = true)
    end
    return nothing
end

"""Copy `rels` from a remote tree. The archive contains those paths only.

Extract lands in an empty directory. Remote mtimes are not kept. Modes are
`0644`, or `0755` when the remote file is executable.
"""
function _pull_tar_rels!(
        host::AbstractString,
        remote_dir::AbstractString,
        local_root::AbstractString,
        rels::AbstractVector{<:AbstractString};
        julia_bin::AbstractString,
        allow_external_symlinks::Bool = false,
    )
    isempty(rels) && return nothing
    tmp = mktempdir()
    try
        _extract_remote_tar!(
            host, remote_dir, tmp;
            julia_bin = julia_bin,
            rels = rels,
            allow_external_symlinks = allow_external_symlinks,
        )
        for rel in rels
            src = joinpath(tmp, rel)
            ispath(src) || islink(src) || continue
            _collect_dest_escapes_root(local_root, rel) && throw(
                ArgumentError("collect path escapes $local_root: $rel"),
            )
            _copy_collected_path!(src, joinpath(local_root, rel))
        end
    finally
        rm(tmp; force = true, recursive = true)
    end
    return nothing
end

function _pull_tar_tree!(
        host::AbstractString,
        remote_dir::AbstractString,
        local_root::AbstractString;
        julia_bin::AbstractString,
        allow_external_symlinks::Bool = false,
    )
    tmp = mktempdir()
    try
        _extract_remote_tar!(
            host, remote_dir, tmp;
            julia_bin = julia_bin,
            allow_external_symlinks = allow_external_symlinks,
        )
        for rel in _extracted_rel_paths(tmp)
            _copy_collected_path!(joinpath(tmp, rel), joinpath(local_root, rel))
        end
    finally
        rm(tmp; force = true, recursive = true)
    end
    return nothing
end

"""Run rsync with `--from0 --files-from` via a temp list, not `stdin`.

Julia 1.14 `pipeline(; stdin=buf)` waits for the write and throws `EPIPE` if the
child exits without reading stdin (fake rsync, or rsync dying on argv). A list
file is the same rsync contract without that pipe. NUL framing keeps entries
unambiguous. `./` protects a leading `#` or `;` from rsync's comment syntax.
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
            entry = !isempty(rel) && first(rel) in ('#', ';') ? string("./", rel) : rel
            write(io, entry, '\0')
        end
        close(io)
        cmd = Cmd(
            vcat(rsync_bin, opts, ["--from0", "--files-from=$path", String(src), String(dest)]),
        )
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

"""`git check-ignore -v -z` records: source, line, pattern, pathname."""
function _parse_check_ignore_verbose(
        raw::AbstractString,
    )::Vector{@NamedTuple{source::String, line::String, pattern::String, path::String}}
    parts = split(String(raw), '\0'; keepempty = true)
    if !isempty(parts) && isempty(last(parts))
        pop!(parts)
    end
    recs = @NamedTuple{source::String, line::String, pattern::String, path::String}[]
    i = 1
    n = length(parts)
    while i + 3 <= n
        pattern = String(parts[i + 2])
        path = replace(String(parts[i + 3]), '\\' => '/')
        push!(
            recs,
            (source = String(parts[i]), line = String(parts[i + 1]), pattern = pattern, path = path),
        )
        i += 4
    end
    i <= n && error("git check-ignore returned a truncated record")
    return recs
end

function _info_exclude_source(source::AbstractString)::Bool
    s = replace(String(source), '\\' => '/')
    return s == ".git/info/exclude" || endswith(s, "/.git/info/exclude")
end

"""True when every failed process in `e` exited 1 (`check-ignore`: no match)."""
function _check_ignore_no_match(e)::Bool
    e isa ProcessFailedException || return false
    saw_one = false
    for proc in e.procs
        code = proc.exitcode
        code == 0 && continue
        code == 1 || return false
        saw_one = true
    end
    return saw_one
end

"""
`check-ignore -v --stdin -z` for `rels`, with `core.excludesFile` cleared.

Paths are checked without a trailing slash so `output/*` does not ignore
`output` while `build/` still ignores `build`. Exit 1 and empty stderr means
no match. Any other failure is an error, even when stderr is empty. `-n`
also prints paths that matched nothing (empty source).
"""
function _git_check_ignore_records(
        dir::AbstractString,
        rels::Vector{String};
        nonmatching::Bool = false,
    )::Vector{@NamedTuple{source::String, line::String, pattern::String, path::String}}
    isempty(rels) && return @NamedTuple{source::String, line::String, pattern::String, path::String}[]
    return mktemp() do path, io
        for rel in rels
            r = replace(String(rel), '\\' => '/')
            endswith(r, "/") && (r = r[1:(end - 1)])
            isempty(r) && continue
            write(io, r)
            write(io, UInt8(0))
        end
        close(io)
        out_buf = IOBuffer()
        err_buf = IOBuffer()
        args = String["-C", String(dir), "-c", "core.excludesFile=", "check-ignore", "-v"]
        nonmatching && push!(args, "-n")
        push!(args, "--stdin", "-z")
        try
            run(
                pipeline(
                    _git_cmd(args);
                    stdin = path,
                    stdout = out_buf,
                    stderr = err_buf,
                )
            )
        catch e
            _rethrow_missing_host_tool(e)
            detail = strip(String(take!(err_buf)))
            # Exit 1 is check-ignore's "nothing matched", not a failed command.
            no_match = _check_ignore_no_match(e) && isempty(detail)
            if !no_match
                msg = isempty(detail) ?
                    "git check-ignore failed in $dir" :
                    "git check-ignore failed in $dir:\n$detail"
                error(msg)
            end
        end
        return _parse_check_ignore_verbose(String(take!(out_buf)))
    end
end

"""
Paths in `rels` that a `.gitignore` ignores.

`core.excludesFile` is cleared. A match from `.git/info/exclude` is kept in
the send list, matching `ls-files --exclude-per-directory=.gitignore`.
`check-ignore -v` still prints a path whose last pattern starts with `!`.
That path is not ignored.
"""
function _git_check_ignore_set(dir::AbstractString, rels::Vector{String})::Set{String}
    ignored = Set{String}()
    for rec in _git_check_ignore_records(dir, rels)
        _info_exclude_source(rec.source) && continue
        isempty(rec.source) && continue
        isempty(rec.path) && continue
        startswith(rec.pattern, "!") && continue
        push!(ignored, rec.path)
    end
    return ignored
end

"""True when `source` is a `.gitignore` in a parent of `send_dir`."""
function _gitignore_source_above(
        work_tree::AbstractString,
        send_dir::AbstractString,
        source::AbstractString,
    )::Bool
    src = replace(String(source), '\\' => '/')
    (src == ".gitignore" || endswith(src, "/.gitignore")) || return false
    parent = dirname(src)
    # `dirname(".gitignore")` is `""`, not `"."`.
    ignore_dir = isempty(parent) || parent == "." ? String(work_tree) : joinpath(work_tree, parent)
    _path_under_resolved(send_dir, ignore_dir) || return false
    send = canonical_local_path(send_dir)
    ignore = canonical_local_path(ignore_dir)
    send == ignore && return false
    (ispath(send) && ispath(ignore)) || return true
    return canonical_local_path(realpath(send)) != canonical_local_path(realpath(ignore))
end

"""True when `a` and `b` are the same directory, including via a symlink."""
function _same_resolved_dir(a::AbstractString, b::AbstractString)::Bool
    left = canonical_local_path(a)
    right = canonical_local_path(b)
    left == right && return true
    (ispath(left) && ispath(right)) || return false
    return canonical_local_path(realpath(left)) == canonical_local_path(realpath(right))
end

"""
Paths passed to the first `check-ignore` for the ancestor warning.

A locally ignored directory is one path (`output/`), not each file inside it.
The send root being the work tree returns an empty list: no parent `.gitignore` exists.
"""
function _ancestor_gitignore_probes(send_dir::AbstractString)::Vector{String}
    top = git_work_tree(send_dir)
    top isa String || return String[]
    _same_resolved_dir(top, send_dir) && return String[]
    probes = String[]
    for rel in _git_ls_files_z(
            send_dir,
            ["--others", "--ignored", "--directory", "--exclude-per-directory=.gitignore"],
        )
        r = replace(String(rel), '\\' => '/')
        endswith(r, "/") && (r = r[1:(end - 1)])
        isempty(r) && continue
        push!(probes, r)
    end
    return probes
end

"""
One warning when untracked files are missing because a `.gitignore` above
`send_dir` excluded them. The send list itself is unchanged.
"""
function _warn_ancestor_gitignore!(send_dir::AbstractString, listed::Vector{String})
    top = git_work_tree(send_dir)
    top isa String || return nothing
    _same_resolved_dir(top, send_dir) && return nothing
    present = Set{String}(replace(String(rel), '\\' => '/') for rel in listed)
    probes = _ancestor_gitignore_probes(send_dir)
    isempty(probes) && return nothing
    hits = Tuple{String, String, String}[]
    expand = Tuple{String, String, String}[]
    seen_dir = Set{String}()
    for rec in _git_check_ignore_records(send_dir, probes; nonmatching = true)
        isempty(rec.source) && continue
        _info_exclude_source(rec.source) && continue
        startswith(rec.pattern, "!") && continue
        _gitignore_source_above(top, send_dir, rec.source) || continue
        full = joinpath(send_dir, rec.path)
        if isdir(full) && !islink(full)
            rec.path in seen_dir && continue
            push!(seen_dir, rec.path)
            push!(expand, (rec.path, rec.source, rec.line))
        else
            rec.path in present && continue
            (isfile(full) || islink(full)) || continue
            push!(hits, (rec.path, rec.source, rec.line))
        end
    end
    for (dir, source, line) in expand
        for rel in _git_ls_files_z(
                send_dir,
                ["--others", "--ignored", "--exclude-per-directory=.gitignore", "--", dir],
            )
            r = replace(String(rel), '\\' => '/')
            endswith(r, "/") && continue
            r in present && continue
            full = joinpath(send_dir, r)
            (isfile(full) || islink(full)) || continue
            push!(hits, (r, source, line))
        end
    end
    isempty(hits) && return nothing
    n = length(hits)
    show_n = min(3, n)
    buf = IOBuffer()
    noun = n == 1 ? "file" : "files"
    println(buf, "Warning: $n untracked $noun left out by a .gitignore above this directory.")
    for i in 1:show_n
        path, source, line = hits[i]
        println(buf, "  $path ($source:$line)")
    end
    extra = n - show_n
    extra > 0 && println(buf, "  and $extra more.")
    print_warn(String(take!(buf)))
    return nothing
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
    # Collect then classify in one `check-ignore --stdin` (not one git per directory).
    candidates = String[]
    stack = String[String(dir)]
    while !isempty(stack)
        cur = pop!(stack)
        rel_dir = relpath(cur, dir)
        if rel_dir != "."
            push!(candidates, rel_dir)
        end
        for name in readdir(cur; join = false, sort = false)
            name == ".git" && continue
            name == ".distsshkit" && continue
            child = joinpath(cur, name)
            islink(child) && continue
            isdir(child) || continue
            # Submodules store `.git` as a file, not a directory.
            ispath(joinpath(child, ".git")) && continue
            push!(stack, child)
        end
    end
    ignored = _git_check_ignore_set(dir, candidates)
    for rel in candidates
        rel in ignored && continue
        _push_send_rel!(out, prefix, rel)
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
empty (`output/*` keeps `output/`; `build/` does not). A last pattern that
starts with `!` keeps the directory (`*/` then `!keep/` keeps empty `keep/`).
Directory checks use the same two exclusions: `core.excludesFile` is cleared,
and `.git/info/exclude` does not drop a directory.
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
function _rsync_send_list(
        local_root::AbstractString,
        env;
        warn::Bool = false,
    )::Union{Nothing, Vector{String}}
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
    warn && _warn_ancestor_gitignore!(root, filtered)
    isempty(filtered) && throw(ArgumentError("nothing to send from $root"))
    return filtered
end

"""
    rsync_send_list(local_root, env; warn=false) -> Union{Nothing, Vector{String}}

Git send list for a work tree, relative to `local_root`. This is the rsync
file list. `setup --ship-tree` starts from it and also sends
`LocalPreferences.toml` and `JuliaLocalPreferences.toml` beside a shipped
`Project.toml`, including when those files are gitignored.

Returns `nothing` outside a git work tree. The caller then uses rsync's
per-directory `.gitignore` filter (dir-merge). An empty list throws
`ArgumentError`. `warn=true` prints the ancestor-`.gitignore` warning once.
The default does not print it, so a second call does not repeat the warning.

A 0.x patch does not change the paths this function returns.
"""
function rsync_send_list(local_root::AbstractString, env; warn::Bool = false)
    return _rsync_send_list(local_root, env; warn = warn)
end

public rsync_send_list


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
Classify `remote_path` on `host`.

Returns `(:missing|:empty|:nonempty|:error, detail)`. `:error` keeps the
remote command's stderr (or the exception text) so callers do not describe
an SSH failure as an existing tree.
"""
function _remote_dest_probe(
        host::String,
        remote_path::AbstractString,
    )::Tuple{Symbol, String}
    err_buf = IOBuffer()
    try
        result = read(
            pipeline(
                _host_sync_remote_shell_cmd(host, _remote_dest_status_script(remote_path));
                stderr = err_buf,
            ),
            String,
        )
        for line in eachline(IOBuffer(result))
            s = strip(line)
            s == "MISSING" && return (:missing, "")
            s == "EMPTY" && return (:empty, "")
            s == "NONEMPTY" && return (:nonempty, "")
        end
        return (:nonempty, "remote dest probe returned no status")
    catch e
        _rethrow_missing_host_tool(e)
        detail = strip(String(take!(err_buf)))
        isempty(detail) && (detail = sprint(showerror, e))
        code = DistSSHBase._remote_failure_exit_code(e)
        if code isa Int
            detail = DistSSHBase._append_remote_shell_hint(host, code, detail)
        end
        return (:error, detail)
    end
end

"""
Classify `remote_path` on `host`: `:missing`, `:empty`, or `:nonempty`.

Uses `_host_sync_remote_shell_cmd` (honors `DISTSSHKIT_TEST_SSH`).
On SSH/script failure, returns `:nonempty` (fail closed — refuse overwrite).
Callers that can report the failure use [`_remote_dest_probe`](@ref).
"""
function remote_dest_status(host::String, remote_path::AbstractString)::Symbol
    status, _ = _remote_dest_probe(host, remote_path)
    return status === :error ? :nonempty : status
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
        DistSSHBase._throw_if_nonposix_shell(host, e)
        return false
    end
end

function _print_rsync_safety_banner!(
        local_root::AbstractString,
        remote_path::AbstractString,
        hosts::Vector{String},
        path_anchor::AbstractString;
        gitignore::Bool = true,
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
    if !gitignore
        println_fatal("  Sends the tree except `.git/` and `.distsshkit/`. `.gitignore` is not applied.")
    elseif git_work_tree(local_root) isa String
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

"""Tree copy that does not use a send list.

`gitignore=false` excludes only `.git/` and `.distsshkit/`.
"""
function _rsync_tree_cmd(
        rsync_bin::Vector{String},
        ssh_cmd_str::AbstractString,
        local_root::AbstractString,
        dest::AbstractString;
        gitignore::Bool = true,
    )::Cmd
    args = String[
        "-az",
        "-e",
        String(ssh_cmd_str),
        "--exclude",
        ".git/",
        "--exclude",
        ".distsshkit/",
    ]
    if gitignore
        push!(args, "--filter", ":- .gitignore")
    end
    push!(args, local_root * "/", String(dest))
    return Cmd(vcat(rsync_bin, args))
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
        send_list::Union{Nothing, Vector{String}};
        gitignore::Bool = true,
    )
    st, detail = _remote_dest_probe(host, remote_path)
    if st === :error
        return (;
            status = :probe_fail,
            message = "could not inspect remote path: $detail",
            dir_created = false,
        )
    end
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
    # `gitignore=false` sends the whole tree. A send list would apply `.gitignore` again.
    listed = gitignore ? send_list : nothing
    if listed === nothing
        run(
            pipeline(
                _rsync_tree_cmd(
                    _host_sync_rsync_argv(),
                    ssh_cmd_str,
                    local_root,
                    dest;
                    gitignore = gitignore,
                );
                stderr = stderr,
            )
        )
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
            listed::Vector{String},
        )
    end
    return (; status = :ok, message = "", dir_created = dir_created)
end

"""
    rsync_project_to_hosts!(
        hosts, local_root, remote_path;
        confirm=true, report=false, path_anchor=local_root, gitignore=true,
    )

Rsync `local_root/` to `remote_path` on each SSH host. Returns
`(cancelled, succeeded, failed, host_results)`.

Refuses hosts where `remote_path` already has any entries (safety). Use
`setup --delete` first to replace an existing tree. Missing or empty
directories are created/filled.

When `confirm=true`, prints warnings and requires typing `rsync` (unless
[`kit_noninteractive`](@ref) / `--yes` is active — then confirmation is skipped,
but the nonempty-path refusal still applies).

`gitignore=false` sends the tree except `.git/` and `.distsshkit/`. The
caller has already chosen what to send. The default follows `.gitignore`.
"""
function rsync_project_to_hosts!(
        hosts::Vector{String},
        local_root::AbstractString,
        remote_path::AbstractString;
        confirm::Bool = true,
        report::Bool = false,
        path_anchor::AbstractString = local_root,
        gitignore::Bool = true,
    )::NamedTuple
    given = canonical_local_path(local_root)
    env0 = resolve_pkg_env(given)
    # Workspace members resolve `env_dir` to the parent root; list paths relative to that.
    send_list = gitignore ? _rsync_send_list(env0.env_dir, env0; warn = true) : nothing
    shipped = ensure_manifest_ships!(
        given; send_list = send_list, warn_send_list = gitignore,
    )
    local_root = shipped.env_dir
    raw_anchor = canonical_local_path(path_anchor)
    anchor = raw_anchor == given ? local_root : raw_anchor
    remote_path = _checked_remote_dest(remote_path)

    if confirm && !kit_noninteractive()
        cancelled = let anchor = anchor
            with_kit_progress_suspended() do
                _print_rsync_safety_banner!(
                    local_root, remote_path, hosts, anchor; gitignore = gitignore,
                )
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
                    _rsync_one_host!(
                        host, local_root, remote_path, ssh_cmd_str, send_list;
                        gitignore = gitignore,
                    )
                end
            else
                _rsync_one_host!(
                    host, local_root, remote_path, ssh_cmd_str, send_list;
                    gitignore = gitignore,
                )
            end
            if outcome.status === :busy || outcome.status === :mkdir_fail ||
                    outcome.status === :probe_fail
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
