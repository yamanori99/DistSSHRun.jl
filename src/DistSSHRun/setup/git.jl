# Git push/pull sync to SSH hosts (shared by `setup --sync` / `--pull` and `sync!`).

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

function git_pull_local_project!(project::AbstractString)::Bool
    return _git_run_detail(["-C", String(project), "pull"]).ok
end

"""Remote shell snippet for `git pull` at `remote_path` (`ssh -n`, not a login shell)."""
function _git_pull_remote_inner(remote_path::AbstractString)::String
    return "cd $(_remote_shell_path_word(remote_path)) && git pull"
end

function _git_pull_remote_host_detail(host::AbstractString, remote_path::AbstractString)
    out_buf = IOBuffer()
    err_buf = IOBuffer()
    try
        run(
            pipeline(
                _host_sync_remote_shell_cmd(String(host), _git_pull_remote_inner(remote_path));
                stdout = out_buf,
                stderr = err_buf,
            )
        )
        return (; ok = true, detail = "")
    catch e
        _rethrow_missing_host_tool(e)
        return (;
            ok = false,
            detail = _captured_output_tail(String(take!(out_buf)), String(take!(err_buf))),
        )
    end
end

function git_pull_remote_host!(host::AbstractString, remote_path::AbstractString)::Bool
    return _git_pull_remote_host_detail(host, remote_path).ok
end

function _git_remote_url(project::AbstractString)::String
    try
        return strip(read(pipeline(_git_cmd(["-C", String(project), "remote", "get-url", "origin"]); stderr = devnull), String))
    catch e
        _rethrow_missing_host_tool(e)
        return "<repo_url>"
    end
end

function _print_git_sync_banner!(
        hosts::Vector{String},
        project::AbstractString,
        remote_path::AbstractString;
        do_push::Bool,
        do_pull::Bool,
        do_local_pull::Bool,
    )
    # Consent text: always on the terminal (same gate as `kit_confirm`).
    println_fatal("  Repository: $(_git_remote_url(project))")
    println_fatal("  Remote path: $remote_path")
    println_fatal("  Hosts: $(join(hosts, ", "))")
    println_fatal()
    println_fatal("  This will:")
    do_local_pull && println_fatal("    git pull on localhost")
    if do_push
        print_warn("    git push (local → origin; not only the listed hosts)\n")
    end
    do_pull && println_fatal("    git pull on remotes")
    println_fatal()
    return nothing
end

"""
    git_sync_project_to_hosts!(
        hosts, project, remote_path;
        do_push=true, do_pull=true, do_local_pull=false, confirm=true,
    ) -> (; ok, cancelled, host_results)

Push/pull git so remotes match `project`. Used by `setup --sync` / `--pull` and
[`sync!`](@ref) (`mode=:sync`).

When `confirm=true`, prints the planned git steps and requires `y` (unless
[`kit_noninteractive`](@ref) / `--yes` is active).
"""
function git_sync_project_to_hosts!(
        hosts::Vector{String},
        project::AbstractString,
        remote_path::AbstractString;
        do_push::Bool = true,
        do_pull::Bool = true,
        do_local_pull::Bool = false,
        confirm::Bool = true,
    )
    ensure_manifest_in_git_worktree!(project)
    proj = canonical_local_path(project)
    remote = String(remote_path)
    host_results = HostResult[]

    if confirm && !kit_noninteractive()
        cancelled = with_kit_progress_suspended() do
            _print_git_sync_banner!(
                hosts, proj, remote;
                do_push = do_push, do_pull = do_pull, do_local_pull = do_local_pull,
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

    if do_local_pull
        local_r = kit_spin!("  localhost git pull: ") do
            _git_run_detail(["-C", proj, "pull"])
        end
        if local_r.ok
            print_ok("✓")
            kit_println()
        else
            print_progress_err("✗")
            kit_println()
            isempty(local_r.detail) || println_fatal(local_r.detail)
            return (; ok = false, cancelled = false, host_results = host_results)
        end
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
            pull_r = _setup_host_call!(host) do
                kit_spin!("  $host git pull: ") do
                    _git_pull_remote_host_detail(host, remote)
                end
            end
            if pull_r.ok
                print_ok("✓")
                kit_println()
                push!(host_results, HostResult(host, true, "git pull ok"))
            else
                print_progress_err("✗")
                kit_println()
                msg = isempty(pull_r.detail) ? "git pull failed" : pull_r.detail
                push!(host_results, HostResult(host, false, msg))
                return (; ok = false, cancelled = false, host_results = host_results)
            end
        end
    end

    kit_println()
    return (; ok = true, cancelled = false, host_results = host_results)
end
