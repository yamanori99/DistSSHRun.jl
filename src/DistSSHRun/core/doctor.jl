# `doctor` deploy checks and launch preflight (shared by go / drive paths).

"""Outcome of a `doctor` run (`doctor_deploy!` today; more groups in 0.2.x)."""
struct DoctorReport
    ok::Bool
    warnings::Vector{SetupWarning}
end

"""CLI exit 2 line when `setup check` is invoked."""
function setup_check_removed_message()::String
    return "setup check was removed in 0.2.0; use: $(cli_m()) doctor --deploy [--ship-id ID] HOSTS"
end

"""
    doctor_deploy_check(hosts, julia_path, remote_path, project; kwargs...) -> DoctorReport

Same checks as the former `setup check` (SSH, Julia, project, deps, git commit parity).
"""
function doctor_deploy_check(
        hosts::Vector{String},
        julia_path::String,
        remote_path::String,
        project::AbstractString;
        path_anchor::AbstractString = project,
        ignore_julia_version::Bool = false,
    )::DoctorReport
    result = check_prerequisites(
        hosts,
        julia_path,
        remote_path,
        project;
        path_anchor = path_anchor,
        require_clean_git = false,
        check_code_sync = true,
        ignore_julia_version = ignore_julia_version,
    )
    return DoctorReport(result.ok, result.warnings)
end

function _doctor_launch_host_ssh_hint(host::AbstractString)::String
    h = String(strip(host))
    if !contains(h, '@') && occursin(r"^(?:\d{1,3}\.){3}\d{1,3}$", h)
        return "hint: use user@$h (e.g. root@$h) if SSH defaults to your local username"
    end
    return ""
end

"""
    doctor_launch_assert_host!(host, remote_root)

SSH reachability, remote `Project.toml`, and instantiate/deps probe (go launch).
"""
function doctor_launch_assert_host!(
        host::AbstractString,
        remote_root::AbstractString;
        local_project::Union{Nothing, AbstractString} = nothing,
    )
    rr = _remote_shell_path_word(remote_root)
    inner = "test -d $rr && test -f $rr/Project.toml"
    cmd = _ssh_cmd(DistSSHBase._ssh_remote_session_argv(String(host), inner))
    out = IOBuffer()
    err = IOBuffer()
    proc = run_ssh(
        pipeline(ignorestatus(cmd); stdout = out, stderr = err);
        wait = true,
    )
    code = DistSSHBase.shell_status(proc)
    if code != 0
        err_text = strip(String(take!(err)))
        ssh_hint = _doctor_launch_host_ssh_hint(host)
        auth_or_conn = code == 255 ||
            occursin("Permission denied", err_text) ||
            occursin("Connection refused", err_text) ||
            occursin("Could not resolve hostname", err_text) ||
            occursin("No route to host", err_text)

        if auth_or_conn
            msg = "cannot SSH to $host"
            !isempty(err_text) && (msg *= ": $(first(split(err_text, '\n')))")
            !isempty(ssh_hint) && (msg *= "\n  $ssh_hint")
            throw(ArgumentError(DistSSHBase._append_remote_shell_hint(String(host), code, msg)))
        end

        msg = "remote project not ready on $host ($remote_root).\n" *
            "Run setup first (pick one deploy path), then instantiate:\n" *
            "  ship:   $(cli_m_project()) setup ship-tree $(setup_cli_host_token(host))\n" *
            "  git:    $(cli_m_project()) setup git-clone $(setup_cli_host_token(host))\n" *
            "          (later updates: setup git-sync $(setup_cli_host_token(host)))\n" *
            "  then:   $(cli_m_project()) setup instantiate $(setup_cli_host_token(host))\n" *
            "  then:   $(cli_m_project()) go --ship-id ID …\n" *
            "Or from Julia: setup!(session, :ship_tree, :instantiate)\n" *
            "  (or :git_clone, :instantiate; repo=\"…\" for clone; later :git_sync)\n" *
            "Set DISTRIBUTED_REMOTE_PROJECT_ROOT if the remote path is not the default."
        !isempty(ssh_hint) && (msg *= "\n  $ssh_hint")
        throw(ArgumentError(DistSSHBase._append_remote_shell_hint(String(host), code, msg)))
    end

    deps_err = probe_remote_project_deps(
        host,
        remote_root;
        local_project = local_project,
    )
    if deps_err !== nothing
        if probe_deps_is_missing_path_message(deps_err)
            throw(ArgumentError(deps_err))
        end
        throw(
            ArgumentError(
                "remote project deps not ready on $host ($remote_root): $deps_err\n" *
                    "Fix: $(cli_m_project()) setup instantiate $(setup_cli_host_token(host))\n" *
                    "  (or setup!(session, :instantiate) after :ship_tree / :git_clone)",
            ),
        )
    end
    return nothing
end

"""Run [`doctor_launch_assert_host!`](@ref) on every host; one combined `ArgumentError` on failure."""
function doctor_launch_assert_hosts!(
        hosts::AbstractVector{<:AbstractString},
        remote_root::AbstractString;
        local_project::Union{Nothing, AbstractString} = nothing,
    )
    errs = String[]
    for h in hosts
        try
            doctor_launch_assert_host!(
                h,
                remote_root;
                local_project = local_project,
            )
        catch e
            push!(errs, sprint(showerror, e))
        end
    end
    isempty(errs) && return nothing
    throw(ArgumentError(join(errs, "\n\n")))
end

"""
    doctor!(session::DistSSHSession; deploy::Bool, julia="auto", ship_id=nothing, kwargs...) -> DoctorReport

Julia API for `julia -m DistSSHKit doctor --deploy …`. Other doctor groups ship in 0.2.x.
"""
function doctor!(
        session::DistSSHSession;
        deploy::Bool,
        julia::AbstractString = "auto",
        ship_id::Union{Nothing, AbstractString} = nothing,
        ignore_julia_version::Bool = false,
    )::DoctorReport
    deploy || throw(
        ArgumentError(
            "doctor!: pass deploy=true (other groups ship in 0.2.x). See help doctor.",
        ),
    )
    isempty(session.hosts) && throw(
        ArgumentError(
            explain_no_hosts(; surface = hint_surface(session), kind = :ssh),
        ),
    )
    validate_setup_hosts(session.hosts)
    snap = ship_id === nothing ? nothing : validate_ship_id(ship_id)
    return _with_kit_inproc_run!(:doctor) do
        return _with_session_env!(session) do
            work_path = _project_work_root(
                session.hosts, session.project;
                cli_override = session.remote, ship_id = snap,
            )
            julia_path = isempty(strip(String(julia))) ? "auto" : String(julia)
            return doctor_deploy_check(
                session.hosts,
                julia_path,
                work_path,
                session.project;
                path_anchor = session.project,
                ignore_julia_version = ignore_julia_version,
            )
        end
    end
end

public doctor_deploy_check
public doctor_launch_assert_host!
public doctor_launch_assert_hosts!
public setup_check_removed_message
