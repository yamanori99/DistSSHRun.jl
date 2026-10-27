# Clone / delete / instantiate / cleanup / rsync CLI ops (shared display + counts).

remote_dir_exists(host::String, remote_path::String)::Bool =
    _remote_dir_exists(host, remote_path)

ensure_remote_dir(host::String, remote_path::String)::Bool =
    _ensure_remote_dir(host, remote_path)

"""
    rsync_push_to_remotes(hosts, remote_path, project; path_anchor=project)

rsync the local project tree to each host, bypassing git entirely (no commit,
no push/pull, no hash verification). Excludes `.git/` and `.distsshkit/`.
Inside a git work tree the send list is `git ls-files` with each directory's
`.gitignore` (negation applies; `.git/info/exclude` and global excludes do not).
Outside one, rsync's per-directory `.gitignore` filter applies, and negation
patterns are not. The destination must be missing or empty.

**Safety:** refuses if `remote_path` already has any files. Delete first with
`setup --delete`, then `--rsync` onto a missing/empty path. For git-managed
remotes, use `setup --sync` / `--pull` for later updates.

Returns `(cancelled, succeeded, failed)`:
- `cancelled=true` when the user did not confirm
- otherwise per-host rsync outcomes (`succeeded` / `failed` counts)
"""
function rsync_push_to_remotes(
        hosts::Vector{String},
        remote_path::String,
        project::AbstractString;
        path_anchor::AbstractString = project,
    )::NamedTuple
    raw = rsync_project_to_hosts!(
        hosts,
        project,
        remote_path;
        confirm = true,
        report = true,
        path_anchor = path_anchor,
    )
    return host_op_result(
        cancelled = raw.cancelled,
        succeeded = raw.succeeded,
        failed = raw.failed,
    )
end

"""Remote `sh` that removes `remote_path` unless it is that host's `~` or `/`."""
function _remote_delete_shell(remote_path::AbstractString)::String
    pq = _remote_shell_path_word(remote_path)
    return """
    if [ -e $pq ]; then
      _distssh_target=\$(cd $pq && pwd -P) || exit 1
      _distssh_home=\$(cd ~ && pwd -P) || exit 1
      if [ "\$_distssh_target" = "\$_distssh_home" ] || [ "\$_distssh_target" = / ]; then
        echo "refusing to delete \$_distssh_target" >&2
        exit 1
      fi
    fi
    rm -rf $pq 2>/dev/null
    if [ -e $pq ]; then
      chmod -R u+rwX $pq 2>/dev/null
      rm -rf $pq
    fi
    """
end

"""
Delete remote repositories.

Returns `(cancelled, succeeded, failed, hosts)`. Caller should use
[`finish_host_op!`](@ref) so partial failure is not reported as success.
Pass `confirm=false` to skip the typed `delete` prompt.
The `setup --delete` CLI does that after `--confirm-path` matches, and also
when `-y` / `DISTSSHKIT_YES` is set. That skip stops in 0.2.
"""
function delete_remotes(
        hosts::Vector{String},
        remote_path::String;
        confirm::Bool = true,
    )::NamedTuple
    _checked_remote_dest(remote_path)
    if confirm && !kit_noninteractive()
        cancelled = with_kit_progress_suspended() do
            print_err("  This will DELETE repositories on all hosts via SSH.\n")
            println_fatal("  Remote path: $remote_path")
            println_fatal("  Hosts: $(join(hosts, ", "))")
            println_fatal("  Note: pass `child:NAME` for SSH hosts; `parent` only with up.")
            println_fatal()
            kit_confirm("Type 'delete' to confirm: "; keyword = "delete") || begin
                println_fatal("Cancelled.")
                return true
            end
            println_fatal()
            return false
        end
        cancelled && return (; cancelled = true, succeeded = 0, failed = 0, hosts = HostResult[])
    end

    succeeded = 0
    failed = 0
    host_results = HostResult[]
    for host in hosts
        _setup_host_span!(host, :running)
        err_buf = IOBuffer()
        try
            kit_spin!("  $host: ") do
                read(
                    pipeline(
                        _host_sync_remote_shell_cmd(host, _remote_delete_shell(remote_path));
                        stderr = err_buf,
                    ),
                    String,
                )
                return nothing
            end
            print_ok("✓")
            kit_println()
            succeeded += 1
            push!(host_results, HostResult(host, true, "deleted"))
            _setup_host_span!(host, :ok)
        catch e
            detail = strip(String(take!(err_buf)))
            report_remote_failure(e; stderr = detail)
            failed += 1
            msg = isempty(detail) ? sprint(showerror, e) : detail
            push!(host_results, HostResult(host, false, msg))
            _setup_host_span!(host, :fail)
        end
    end
    return (; host_op_result(succeeded = succeeded, failed = failed)..., hosts = host_results)
end

"""
Clone repository on remote hosts. Refuses if remote_path already has files.

Returns `(cancelled, succeeded, failed, hosts)`.
Pass `confirm=false` to skip the proceed prompt (CLI `-y` / API `session.yes`).

Runs `git clone` **on each remote**. Private URLs need credentials **on that host**
(deploy key or HTTPS token), not the kit parent's agent.
"""
function clone_to_remotes(
        hosts::Vector{String},
        remote_path::String,
        clone_url::String;
        confirm::Bool = true,
    )::NamedTuple
    _checked_remote_dest(remote_path)
    if confirm && !kit_noninteractive()
        cancelled = with_kit_progress_suspended() do
            println_fatal("  Repository: $clone_url")
            println_fatal("  Remote path: $remote_path")
            println_fatal("  Hosts: $(join(hosts, ", "))")
            println_fatal()
            print_warn("  Safety: refuses if the remote path already has any files.\n")
            println_fatal("  To replace an existing tree, run `setup --delete` first, then `--clone`.")
            println_fatal()
            kit_confirm("Proceed? [y/N]: ") || begin
                println_fatal("Cancelled.")
                return true
            end
            println_fatal()
            return false
        end
        cancelled && return (; cancelled = true, succeeded = 0, failed = 0, hosts = HostResult[])
    end

    pq = _remote_shell_path_word(remote_path)
    uq = _remote_sh_quote(String(clone_url))
    succeeded = 0
    failed = 0
    host_results = HostResult[]
    for host in hosts
        _setup_host_span!(host, :running)
        out_buf = IOBuffer()
        err_buf = IOBuffer()
        try
            outcome = kit_spin!("  $host: ") do
                st, detail = _remote_dest_probe(host, remote_path)
                if st === :error
                    return (:probe_fail, "could not inspect remote path: $detail")
                end
                if st === :nonempty
                    return (:busy, remote_dest_busy_message(host, remote_path))
                end
                if st === :missing
                    parent = _remote_clone_parent(remote_path)
                    if parent !== nothing && !_ensure_remote_dir(host, parent)
                        return (:mkdir_fail, "could not create parent of remote clone path")
                    end
                end
                run(
                    pipeline(
                        _host_sync_remote_shell_cmd(host, "git clone -- $uq $pq");
                        stdout = out_buf,
                        stderr = err_buf,
                    )
                )
                return (:ok, "")
            end
            if outcome[1] !== :ok
                print_err("✗ $(outcome[2])")
                println()
                failed += 1
                push!(host_results, HostResult(host, false, outcome[2]))
                _setup_host_span!(host, :fail)
                continue
            end
            print_ok("✓")
            kit_println()
            succeeded += 1
            push!(host_results, HostResult(host, true, "cloned"))
            _setup_host_span!(host, :ok)
        catch e
            detail = _captured_output_tail(String(take!(out_buf)), String(take!(err_buf)))
            report_remote_failure(e; stderr = detail)
            failed += 1
            msg = isempty(detail) ? sprint(showerror, e) : detail
            push!(host_results, HostResult(host, false, msg))
            _setup_host_span!(host, :fail)
        end
    end
    return (; host_op_result(succeeded = succeeded, failed = failed)..., hosts = host_results)
end

"""Parent of a remote clone destination, or `nothing` when it is already `/` or `~`."""
function _remote_clone_parent(remote_path::AbstractString)::Union{Nothing, String}
    path = rstrip(strip(String(remote_path)), '/')
    parent = dirname(path)
    (isempty(parent) || parent == path || parent == "." || parent == "/") && return nothing
    occursin(r"^~[^/]*$", parent) && return nothing
    return parent
end

"""
Kill stale Julia worker processes on localhost and remote hosts.

Returns `(cancelled=false, succeeded, failed, hosts)` for the SSH hosts only
(localhost cleanup is always attempted and not counted as a remote failure).
"""
function cleanup_remote_workers(hosts::Vector{String})::NamedTuple
    kit_spin!("  localhost: ") do
        _pkill_local_julia_workers!()
        return nothing
    end
    print_ok("✓")
    kit_println()

    n = length(hosts)
    oks = fill(false, n)
    kit_spin!("  Cleaning remotes ($(length(hosts))) ") do
        map_host_jobs(hosts) do i, host
            _setup_host_span!(host, :running)
            okh = _pkill_remote_julia_workers!(host)
            oks[i] = okh
            _setup_host_span!(host, okh ? :ok : :fail)
        end
        return nothing
    end
    kit_println()

    succeeded = 0
    failed = 0
    host_results = HostResult[]
    for i in 1:n
        host = hosts[i]
        if oks[i]
            ok("$host: done")
            succeeded += 1
            push!(host_results, HostResult(host, true, "cleaned"))
        else
            fail("$host: SSH unreachable")
            failed += 1
            push!(host_results, HostResult(host, false, "SSH unreachable"))
        end
    end
    return (; host_op_result(succeeded = succeeded, failed = failed)..., hosts = host_results)
end

"""
Run `using Pkg; <pkg_e>` on remote hosts (parallel) with `--project` at `remote_path`.

Returns `(cancelled=false, succeeded, failed)`.
Private git deps need a deploy key or HTTPS token on the remote. Uses
`JULIA_PKG_USE_CLI_GIT=true` so Pkg prefers the `git` CLI over LibGit2.
"""
function _pkg_e_on_remotes(
        hosts::Vector{String},
        julia_path::String,
        remote_path::String,
        project::AbstractString;
        path_anchor::AbstractString = project,
        pkg_e::AbstractString,
        spin_label::AbstractString,
    )::NamedTuple
    kit_println("  Local project: $(cli_project_disp(project, path_anchor))")
    kit_println("  Remote --project: $remote_path")
    kit_println()

    for host in hosts
        kit_println("  $host: queued")
    end

    pq = _remote_shell_path_word(remote_path)
    n = length(hosts)
    oks = fill(false, n)
    fail_msgs = fill("", n)
    kit_spin!("  $spin_label ($(length(hosts)) hosts) ") do
        map_host_jobs(hosts) do i, host
            _setup_host_span!(host, :running)
            host_julia = nothing
            ssh_msg = nothing
            try
                host_julia = julia_path == "auto" ? detect_julia_path(host) : julia_path
            catch e
                e isa ArgumentError || rethrow()
                ssh_msg = e.msg
            end
            if ssh_msg isa String
                oks[i] = false
                fail_msgs[i] = ssh_msg
            elseif host_julia === nothing
                oks[i] = false
                fail_msgs[i] = "Julia not found"
            else
                jb = _remote_shell_path_word(host_julia)
                # Prefer git CLI (ssh-agent / SSH config) over LibGit2 credentials UI.
                cmd = "JULIA_PKG_USE_CLI_GIT=true $jb --project=$pq --startup-file=no " *
                    "-e 'using Pkg; $pkg_e'"
                out = IOBuffer()
                err = IOBuffer()
                try
                    proc = run(
                        pipeline(
                            ignorestatus(_host_sync_remote_shell_cmd(host, cmd));
                            stdout = out,
                            stderr = err,
                        );
                        wait = true,
                    )
                    if proc.exitcode == 0
                        oks[i] = true
                    else
                        oks[i] = false
                        msg = strip(String(take!(err)))
                        isempty(msg) && (msg = strip(String(take!(out))))
                        fail_msgs[i] = isempty(msg) ? "exit $(proc.exitcode)" : first(split(msg, '\n'))
                    end
                catch e
                    oks[i] = false
                    fail_msgs[i] = sprint(showerror, e)
                end
            end
            _setup_host_span!(host, oks[i] ? :ok : :fail)
        end
        return nothing
    end
    kit_println()

    succeeded = 0
    failed = 0
    host_results = HostResult[]
    for i in 1:n
        host = hosts[i]
        if oks[i]
            ok("$host: done")
            succeeded += 1
            push!(host_results, HostResult(host, true, "done"))
        else
            fail("$host: failed")
            msg = fail_msgs[i]
            !isempty(msg) && kit_println("    $msg")
            if occursin("credential", lowercase(msg)) || occursin("Permission denied", msg) ||
                    occursin("failed to clone", lowercase(msg))
                kit_println("    Hint: remote needs a deploy key or HTTPS token for private deps.")
                kit_println("          (JULIA_PKG_USE_CLI_GIT is already set for this step)")
            end
            failed += 1
            push!(host_results, HostResult(host, false, isempty(msg) ? "failed" : msg))
        end
    end
    return (; cancelled = false, succeeded, failed, hosts = host_results)
end

function instantiate_remotes(
        hosts::Vector{String},
        julia_path::String,
        remote_path::String,
        project::AbstractString;
        path_anchor::AbstractString = project,
    )::NamedTuple
    ensure_manifest_ships!(project)
    return _pkg_e_on_remotes(
        hosts, julia_path, remote_path, project;
        path_anchor = path_anchor,
        pkg_e = "Pkg.instantiate()",
        spin_label = "Instantiating",
    )
end

"""Run `Pkg.test()` of the **job** project on remote hosts (not DistSSHRun's tests)."""
function runtest_remotes(
        hosts::Vector{String},
        julia_path::String,
        remote_path::String,
        project::AbstractString;
        path_anchor::AbstractString = project,
    )::NamedTuple
    return _pkg_e_on_remotes(
        hosts, julia_path, remote_path, project;
        path_anchor = path_anchor,
        pkg_e = "Pkg.test()",
        spin_label = "Pkg.test",
    )
end

"""Resolve clone URL: `--repo` / `repo=` wins, else local `origin` (HTTPS GitHub → SSH)."""
function resolve_clone_url(
        repo_override::Union{Nothing, String},
        project::AbstractString;
        surface::Symbol = :cli,
    )
    if repo_override isa String
        repo = repo_override::String
        url = strip(repo)
        if !isempty(url)
            return normalize_git_clone_url(url)
        end
    end
    url = clone_url_from_local_origin(project)
    url === nothing && error(explain_clone_origin_missing(; surface = surface))
    return url
end
