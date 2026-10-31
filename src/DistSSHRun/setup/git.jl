# Git SHA checkout on SSH hosts (shared by `setup --sync` / `--pull` and `sync!`).

"""Last lines of captured stdout and stderr, for a failed git or ssh command."""
function _captured_output_tail(out::AbstractString, err::AbstractString; n::Int = 20)::String
    parts = String[]
    o = strip(String(out))
    e = strip(String(err))
    isempty(o) || push!(parts, o)
    isempty(e) || push!(parts, e)
    text = join(parts, "\n")
    lines = split(text, '\n'; keepempty = false)
    isempty(lines) && return ""
    return join(lines[max(1, end - n + 1):end], "\n")
end

function _git_run_detail(args::Vector{String})
    out_buf = IOBuffer()
    err_buf = IOBuffer()
    try
        run(pipeline(_git_cmd(args); stdout = out_buf, stderr = err_buf))
        return (; ok = true, detail = "")
    catch e
        _rethrow_missing_host_tool(e)
        return (;
            ok = false,
            detail = _captured_output_tail(String(take!(out_buf)), String(take!(err_buf))),
        )
    end
end

function git_push_project!(project::AbstractString)::Bool
    return _git_run_detail(["-C", String(project), "push"]).ok
end

# Mandatory on every remote git process. Ephemeral `-c` only: do not set
# `safe.directory` or any other persistent config.
const _REMOTE_GIT_CONFIG_ARGS = (
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "advice.detachedHead=false",
    "-c",
    "submodule.recurse=false",
    "-c",
    "gc.auto=0",
    "-c",
    "core.autocrlf=false",
    "--no-optional-locks",
)

"""`:world`, `:group`, or `nothing` from an `ls -ldL` mode (`drwxrwxrwx`)."""
function _ls_mode_writable_kind(mode::AbstractString)::Union{Nothing, Symbol}
    m = String(mode)
    length(m) < 10 && return nothing
    m[9] == 'w' && return :world
    m[6] == 'w' && return :group
    return nothing
end

"""True when `mode` is an `ls -ldL` directory mode, including an ACL mark."""
function _ls_directory_mode(mode::AbstractString)::Bool
    m = String(mode)
    return length(m) >= 10 && m[1] == 'd'
end

"""Remote `sh` that prints `missing` or the `ls -ldL` mode of `abs_path`.

`-L` follows a symlink so the mode is the directory Git uses, not `lrwxrwxrwx`.
`-l` stays so the first field is the mode. `ls` failure exits 1. A pipeline
that drops that status is not a private directory.
"""
function _remote_project_mode_sh(abs_path::AbstractString)::String
    q = _remote_shell_path_word(abs_path)
    return "if [ ! -d $q ]; then echo missing; exit 0; fi; " *
        "mode=\$(ls -ldL $q) || exit 1; " *
        "printf '%s\\n' \"\$mode\" | awk '{ print \$1; exit }'"
end

function _remote_project_mode(host::AbstractString, abs_path::AbstractString)
    out_buf = IOBuffer()
    err_buf = IOBuffer()
    try
        run(
            pipeline(
                _host_sync_remote_shell_cmd(String(host), _remote_project_mode_sh(abs_path));
                stdout = out_buf,
                stderr = err_buf,
            ),
        )
    catch e
        _rethrow_missing_host_tool(e)
        return (;
            ok = false,
            kind = :probe_failed,
            detail = _captured_output_tail(String(take!(out_buf)), String(take!(err_buf))),
        )
    end
    line = strip(String(take!(out_buf)))
    line == "missing" && return (; ok = true, kind = :missing, detail = "")
    token = isempty(line) ? "" : String(first(split(line)))
    _ls_directory_mode(token) || return (;
        ok = false,
        kind = :probe_failed,
        detail = isempty(token) ? "could not read the project mode" : token,
    )
    kind = _ls_mode_writable_kind(token)
    return (; ok = true, kind = something(kind, :private), detail = token)
end

"""
Remote `sh` body for one `git` at `remote_path`.

Every remote git call goes through here so hooks, fsmonitor, and optional locks do not run.
Arguments are passed through [`_remote_argv_sh`](@ref). A `~` path is `cd`
then `git` so the remote shell expands the tilde; any other path is `git -C`.
"""
function _remote_git_shell(
        remote_path::AbstractString,
        args::AbstractVector{<:AbstractString},
    )::String
    path = strip(String(remote_path))
    argv = String["git"]
    for opt in _REMOTE_GIT_CONFIG_ARGS
        push!(argv, String(opt))
    end
    if startswith(path, "~")
        for a in args
            push!(argv, String(a))
        end
        return "cd $(_remote_shell_path_word(path)) && " * DistSSHBase._remote_argv_sh(argv)
    end
    push!(argv, "-C", path)
    for a in args
        push!(argv, String(a))
    end
    return DistSSHBase._remote_argv_sh(argv)
end

"""Remote `sh` for `git clone`. Same `-c` and `--no-optional-locks` as [`_remote_git_shell`](@ref).

`umask 022` keeps the new tree from being group- or world-writable. The
destination stays outside the quoted argv so a `~` path still expands.
"""
function _remote_git_clone_sh(
        remote_path::AbstractString,
        clone_url::AbstractString,
    )::String
    argv = String["git"]
    for opt in _REMOTE_GIT_CONFIG_ARGS
        push!(argv, String(opt))
    end
    push!(argv, "clone", "--", String(clone_url))
    return "umask 022 && " *
        DistSSHBase._remote_argv_sh(argv) *
        " " *
        _remote_shell_path_word(remote_path)
end

function _git_remote_url(project::AbstractString)::String
    try
        return strip(read(pipeline(_git_cmd(["-C", String(project), "remote", "get-url", "origin"]); stderr = devnull), String))
    catch e
        _rethrow_missing_host_tool(e)
        return "<repo_url>"
    end
end

# `git rev-parse` prints lowercase hex. Reject anything else before it is quoted
# into a remote command or a ref name.
# `\z` rejects a trailing newline. Julia's `$` matches before that newline.
const _GIT_SHA_RE = r"\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z"

function _git_sha_valid(sha::AbstractString)::Bool
    return occursin(_GIT_SHA_RE, sha)
end

function _process_failed_code(e)::Int
    e isa ProcessFailedException || return 1
    procs = e.procs
    return isempty(procs) ? 1 : procs[end].exitcode
end

function _git_run_capture(args::Vector{String}; git_ssh::Union{Nothing, String} = nothing)
    out_buf = IOBuffer()
    err_buf = IOBuffer()
    cmd = _git_cmd(args)
    git_ssh isa String && (cmd = addenv(cmd, "GIT_SSH_COMMAND" => git_ssh))
    try
        run(pipeline(cmd; stdout = out_buf, stderr = err_buf))
        return (; ok = true, code = 0, out = String(take!(out_buf)), err = String(take!(err_buf)), detail = "")
    catch e
        _rethrow_missing_host_tool(e)
        out = String(take!(out_buf))
        err = String(take!(err_buf))
        return (;
            ok = false,
            code = _process_failed_code(e),
            out = out,
            err = err,
            detail = _captured_output_tail(out, err),
        )
    end
end

"""`ssh://host/abs` with the path percent-encoded. `host` may be `user@name`."""
function _percent_encode_git_path(path::AbstractString)::String
    io = IOBuffer()
    for b in codeunits(String(path))
        safe = b == UInt8('/') ||
            (UInt8('A') <= b <= UInt8('Z')) ||
            (UInt8('a') <= b <= UInt8('z')) ||
            (UInt8('0') <= b <= UInt8('9')) ||
            b == UInt8('-') || b == UInt8('.') || b == UInt8('_') || b == UInt8('~')
        if safe
            write(io, b)
        else
            print(io, '%', uppercase(string(Int(b); base = 16, pad = 2)))
        end
    end
    return String(take!(io))
end

function _git_ssh_repo_url(host::AbstractString, abs_path::AbstractString)::String
    path = String(abs_path)
    startswith(path, "/") || error("internal: git push path must be absolute")
    return "ssh://$(String(host))$(_percent_encode_git_path(path))"
end

"""Kit `ssh` plus [`ssh_opts`](@ref), as `GIT_SSH_COMMAND` (git splits this itself)."""
function _kit_git_ssh_command()::String
    parts = String[_ssh_exe()]
    append!(parts, ssh_opts())
    return join((posix_quote(p) for p in parts), " ")
end

function _remote_git_run(
        host::AbstractString,
        remote_path::AbstractString,
        args::Vector{String},
    )
    out_buf = IOBuffer()
    err_buf = IOBuffer()
    try
        run(
            pipeline(
                _host_sync_remote_shell_cmd(String(host), _remote_git_shell(remote_path, args));
                stdout = out_buf,
                stderr = err_buf,
            ),
        )
        return (; ok = true, code = 0, out = String(take!(out_buf)), err = String(take!(err_buf)), detail = "")
    catch e
        _rethrow_missing_host_tool(e)
        out = String(take!(out_buf))
        err = String(take!(err_buf))
        detail = _captured_output_tail(out, err)
        # Failure-only login-shell check. Exit 255 and an inconclusive probe
        # leave `detail` as the captured git output.
        code = DistSSHBase._remote_failure_exit_code(e)
        if code isa Int
            detail = DistSSHBase._append_remote_shell_hint(String(host), code, detail)
        end
        return (;
            ok = false,
            code = _process_failed_code(e),
            out = out,
            err = err,
            detail = detail,
        )
    end
end

"""Keep `message` and append the non-POSIX sentence when `detail` already has it."""
function _with_nonposix_hint(message::AbstractString, detail::AbstractString)::String
    line = nothing
    for raw in eachsplit(String(detail), '\n')
        s = strip(raw)
        startswith(s, "The remote login shell appears to be non-POSIX") || continue
        line = s
    end
    line === nothing && return String(message)
    occursin(line, message) && return String(message)
    return String(message) * "\n" * line
end

function _git_status_args()::Vector{String}
    return String["status", "--porcelain", "-z", "--untracked-files=normal"]
end

function _local_status_dirty(project::AbstractString)
    args = String[
        "-C", String(project),
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
    ]
    append!(args, _git_status_args())
    return _git_run_capture(args)
end

"""`(ok, sha, message)`. `message` is the refusal, already ending in `help setup`."""
function _local_sync_sha(project::AbstractString)
    sha = get_local_git_hash(project)
    if !(sha isa String)
        return (;
            ok = false,
            sha = "",
            message = "This directory has no git commit to check out. See help setup.",
        )
    end
    if !_git_sha_valid(sha)
        return (;
            ok = false,
            sha = "",
            message = "Local git commit is not a 40- or 64-character hex SHA. See help setup.",
        )
    end
    st = _local_status_dirty(project)
    if !st.ok
        detail = isempty(st.detail) ? "git status failed" : st.detail
        return (; ok = false, sha = "", message = detail * "\nSee help setup.")
    end
    if !isempty(st.out)
        return (;
            ok = false,
            sha = "",
            message = "Local git tree is dirty, so sync would not match $sha. " *
                "Commit the changes. A dirty tree is not sent as a patch. See help setup.",
        )
    end
    return (; ok = true, sha = sha, message = "")
end

function _missing_sha_message(host::AbstractString, sha::AbstractString, shallow::Bool)::String
    if shallow
        return "$host is a shallow clone and does not contain $sha. " *
            "Refusing to unshallow it. See help setup."
    end
    return "$host does not contain $sha. See help setup."
end

function _remote_is_shallow(host::AbstractString, abs_path::AbstractString)::Bool
    r = _remote_git_run(host, abs_path, ["rev-parse", "--is-shallow-repository"])
    return r.ok && strip(r.out) == "true"
end

"""Push `sha` to `refs/distssh/<sha>` on the remote repo. Does not update a branch."""
function _git_push_sha_detail(
        project::AbstractString,
        host::AbstractString,
        abs_path::AbstractString,
        sha::AbstractString,
    )
    _git_sha_valid(sha) || error("internal: refusing to push an unvalidated SHA")
    url = _git_ssh_repo_url(host, abs_path)
    refspec = string(sha, ":refs/distssh/", sha)
    return _git_run_capture(
        ["-C", String(project), "push", url, refspec];
        git_ssh = _kit_git_ssh_command(),
    )
end

function _remote_lfs_required(host::AbstractString, abs_path::AbstractString)
    r = _remote_git_run(
        host,
        abs_path,
        ["grep", "-I", "-F", "-e", "filter=lfs", "--", ".gitattributes", ":(glob)**/.gitattributes"],
    )
    r.code == 0 && return (; ok = true, uses = !isempty(strip(r.out)), detail = "")
    r.code == 1 && return (; ok = true, uses = false, detail = "")
    detail = isempty(r.detail) ? "git grep failed" : r.detail
    return (; ok = false, uses = false, detail = detail)
end

"""
Check out `sha` on `host` as a detached HEAD.

Refuses a dirty tree before changing it. A shallow clone that still does not
contain `sha` is an error; this does not unshallow. Submodules follow the
commit. Git LFS runs only when `.gitattributes` asks for it.
"""
function _detach_sha_on_host(
        project::AbstractString,
        host::AbstractString,
        remote_path::AbstractString,
        sha::AbstractString,
    )::NamedTuple{(:ok, :message), Tuple{Bool, String}}
    abs_path = ensure_remote_abs_path(host, remote_path)
    if !(abs_path isa String)
        return (;
            ok = false,
            message = "Could not resolve the remote path on $host. See help setup.",
        )
    end
    mode = _remote_project_mode(host, abs_path)
    if !mode.ok
        detail = isempty(mode.detail) ? "could not read the project mode" : mode.detail
        return (; ok = false, message = "$host: $detail\nSee help setup.")
    end
    if mode.kind === :world || mode.kind === :group
        return (;
            ok = false,
            message = "$host project is $(mode.kind)-writable ($(mode.detail)). " *
                "Refusing to run git there. See help setup.",
        )
    end
    st = _remote_git_run(host, abs_path, _git_status_args())
    if !st.ok
        detail = isempty(st.detail) ? "git status failed" : st.detail
        return (; ok = false, message = "$host: $detail\nSee help setup.")
    end
    if !isempty(st.out)
        return (;
            ok = false,
            message = "$host has untracked or uncommitted files, so checkout would not match $sha. " *
                "Refusing to overwrite them. See help setup.",
        )
    end
    pushed = _git_push_sha_detail(project, host, abs_path, sha)
    if !pushed.ok
        detail = isempty(pushed.detail) ? "git push failed" : pushed.detail
        extra = _remote_is_shallow(host, abs_path) ?
            "\n" * _missing_sha_message(host, sha, true) : ""
        return (; ok = false, message = "git push of $sha to $host failed.\n$detail$extra")
    end
    commit_rev = string(sha, '^', '{', "commit", '}')
    present = _remote_git_run(host, abs_path, ["cat-file", "-e", commit_rev])
    if !present.ok
        return (;
            ok = false,
            message = _with_nonposix_hint(
                _missing_sha_message(host, sha, _remote_is_shallow(host, abs_path)),
                present.detail,
            ),
        )
    end
    checked = _remote_git_run(host, abs_path, ["checkout", "--detach", sha])
    if !checked.ok
        detail = isempty(checked.detail) ? "git checkout failed" : checked.detail
        return (; ok = false, message = "$host: $detail\nSee help setup.")
    end
    sub = _remote_git_run(host, abs_path, ["submodule", "update", "--init", "--recursive"])
    if !sub.ok
        detail = isempty(sub.detail) ? "git submodule update failed" : sub.detail
        return (; ok = false, message = "$host: $detail\nSee help setup.")
    end
    lfs = _remote_lfs_required(host, abs_path)
    if !lfs.ok
        return (; ok = false, message = "$host: $(lfs.detail)\nSee help setup.")
    end
    if lfs.uses
        pulled = _remote_git_run(host, abs_path, ["lfs", "pull"])
        if !pulled.ok
            detail = isempty(pulled.detail) ? "git lfs pull failed" : pulled.detail
            return (;
                ok = false,
                message = "$host uses Git LFS but git lfs pull failed.\n$detail\nSee help setup.",
            )
        end
    end
    head = _remote_git_run(host, abs_path, ["rev-parse", "HEAD"])
    if !head.ok
        detail = isempty(head.detail) ? "could not read git HEAD" : head.detail
        return (; ok = false, message = "$host: $detail\nSee help setup.")
    end
    got = strip(head.out)
    if got != sha
        return (;
            ok = false,
            message = "git HEAD on $host is $got, not $sha. See help setup.",
        )
    end
    after = _remote_git_run(host, abs_path, _git_status_args())
    if !after.ok || !isempty(after.out)
        msg = "$host is dirty after checkout of $sha. See help setup."
        after.ok || (msg = _with_nonposix_hint(msg, after.detail))
        return (; ok = false, message = msg)
    end
    return (; ok = true, message = "detached HEAD at $sha")
end

function _print_git_sync_banner!(
        hosts::Vector{String},
        project::AbstractString,
        remote_path::AbstractString;
        do_push::Bool,
        do_pull::Bool,
    )
    # Consent text: always on the terminal (same gate as `kit_confirm`).
    println_fatal("  Repository: $(_git_remote_url(project))")
    println_fatal("  Remote path: $remote_path")
    println_fatal("  Hosts: $(join(hosts, ", "))")
    println_fatal()
    println_fatal("  This will:")
    if do_push
        print_warn("    git push (local → origin; not only the listed hosts)\n")
    end
    if do_pull
        println_fatal("    push the local commit to refs/distssh/<sha> on each remote")
        println_fatal("    git checkout --detach that commit (detached HEAD)")
    end
    println_fatal()
    return nothing
end

"""
    git_sync_project_to_hosts!(
        hosts, project, remote_path;
        do_push=true, do_pull=true, confirm=true,
    ) -> (; ok, cancelled, host_results)

Make each remote a detached HEAD at the local commit. Used by `setup --sync` /
`--pull` and [`sync!`](@ref) (`mode=:sync`).

Does not run `git pull`. `do_push` still updates `origin`. `do_pull` delivers
the commit with `git push <host>:<path> <sha>:refs/distssh/<sha>` and checks
it out. A dirty local or remote tree is refused and is not sent as a patch.

When `confirm=true`, prints the planned git steps and requires `y` (unless
[`kit_noninteractive`](@ref) / `--yes` is active).
"""
function git_sync_project_to_hosts!(
        hosts::Vector{String},
        project::AbstractString,
        remote_path::AbstractString;
        do_push::Bool = true,
        do_pull::Bool = true,
        confirm::Bool = true,
    )
    ensure_manifest_in_git_worktree!(project)
    proj = canonical_local_path(project)
    remote = String(remote_path)
    host_results = HostResult[]
    local_sha = _local_sync_sha(proj)
    if !local_sha.ok
        println_fatal(local_sha.message)
        return (; ok = false, cancelled = false, host_results = host_results)
    end
    sha = local_sha.sha

    if confirm && !kit_noninteractive()
        cancelled = with_kit_progress_suspended() do
            _print_git_sync_banner!(
                hosts, proj, remote;
                do_push = do_push, do_pull = do_pull,
            )
            kit_confirm("Proceed? [y/N]: ") || begin
                println_fatal("Cancelled.")
                return true
            end
            println_fatal()
            return false
        end
        cancelled && return (; ok = false, cancelled = true, host_results = HostResult[])
    end

    if do_push
        push_r = kit_spin!("  git push: ") do
            _git_run_detail(["-C", proj, "push"])
        end
        if push_r.ok
            print_ok("✓")
            kit_println()
        else
            print_err("✗")
            println_fatal()
            println_fatal()
            repo_url = _git_remote_url(proj)
            print_warn("Push failed.\n")
            isempty(push_r.detail) || println_fatal(push_r.detail)
            println_fatal()
            println_fatal("  Remote: $repo_url")
            println_fatal()
            println_fatal("  Not a team member?")
            println_fatal("    Use --pull instead (fork not needed for experiments)")
            println_fatal()
            println_fatal("  Team member?")
            println_fatal("    git pull --rebase && git push")
            return (; ok = false, cancelled = false, host_results = host_results)
        end
    end

    if do_pull
        for host in hosts
            detached = _setup_host_call!(host) do
                kit_spin!("  $host checkout: ") do
                    _detach_sha_on_host(proj, host, remote, sha)
                end
            end
            if detached.ok
                print_ok("✓")
                kit_println()
                println_fatal("    Detached HEAD at $sha.")
                push!(host_results, HostResult(String(host), true, detached.message))
            else
                print_progress_err("✗")
                kit_println()
                println_fatal(detached.message)
                push!(host_results, HostResult(String(host), false, detached.message))
                return (; ok = false, cancelled = false, host_results = host_results)
            end
        end
    end

    kit_println()
    return (; ok = true, cancelled = false, host_results = host_results)
end
