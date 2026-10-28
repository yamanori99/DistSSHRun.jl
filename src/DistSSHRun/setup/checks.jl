check_ssh(host::String)::Bool = probe_setup_ssh(host) === nothing

"""Print local `ssh` / `rsync` / `git` PATH status. `ssh` missing is a failure; others warn."""
function _report_local_host_tools!(warnings::Vector{SetupWarning} = SetupWarning[])
    ssh = rsync = git = true
    for name in _HOST_TOOL_NAMES
        exe = Sys.which(name)
        found = exe !== nothing
        name == "ssh" && (ssh = found)
        name == "rsync" && (rsync = found)
        name == "git" && (git = found)
        if !found
            if name == "ssh"
                fail("$name not found in PATH")
            else
                msg = "$name not found in PATH"
                warn(msg)
                push!(warnings, SetupWarning(PARENT_HOST_NAME, :tool_missing, msg))
            end
            kit_println("    $(explain_host_tool_hint(name))")
        else
            ok("$name ($exe)")
        end
    end
    return (; ssh, rsync, git)
end

"""Print the remote Julia line. `false` when this host fails the check.

`:minor` fails unless `ignore` is set. `:patch` and `:prerelease` warn either way.
"""
function _report_remote_julia!(
        host::AbstractString,
        checked::AbstractString,
        julia_check,
        ignore::Bool,
        warnings::Vector{SetupWarning} = SetupWarning[],
    )::Bool
    if !julia_check.found
        fail("Julia not found (checked: $checked)")
        print_juliaup_align_fix!(host; kind = :missing)
        return false
    elseif julia_check.mismatch_kind == :minor && !ignore
        fail("Julia version mismatch: local $(VERSION), $host has $(julia_check.version) (at $checked)")
        print_juliaup_align_fix!(host; kind = :mismatch)
        return false
    elseif julia_check.mismatch_kind == :minor
        msg = "Julia version differs: local $(VERSION), $host has $(julia_check.version) (--ignore-julia-version)"
        warn(msg)
        push!(warnings, SetupWarning(String(host), :julia_minor_ignored, msg))
    elseif julia_check.mismatch_kind == :patch
        msg = "Julia patch version differs: local $(VERSION), $host has $(julia_check.version)"
        warn(msg)
        push!(warnings, SetupWarning(String(host), :julia_patch, msg))
    elseif julia_check.mismatch_kind == :prerelease
        msg = "Julia prerelease differs: local $(VERSION), $host has $(julia_check.version)"
        warn(msg)
        push!(warnings, SetupWarning(String(host), :julia_prerelease, msg))
    else
        ok("Julia $(julia_check.version) found at $checked")
    end
    return true
end

"""Check Julia on a remote host: is it present, and does its version match closely enough?

Returns a NamedTuple `(found, version, mismatch_kind)`:
- `found`: whether `julia_path --version` produced parseable output
- `version`: the remote `VersionNumber`, or `nothing` if unparseable
- `mismatch_kind`: see `julia_version_mismatch_kind` (`:none` when `version` is `nothing`)
"""
function check_julia(host::String, julia_path::String)
    remote_version = get_remote_julia_version_full(host, julia_path)
    if remote_version === nothing
        return (found = false, version = nothing, mismatch_kind = :none)
    end
    return (found = true, version = remote_version, mismatch_kind = julia_version_mismatch_kind(VERSION, remote_version))
end

function check_project(host::String, remote_path::String)
    remote_toml = string(rstrip(String(remote_path), '/'), "/Project.toml")
    pq = _remote_shell_path_word(remote_toml)
    try
        result = read(
            pipeline(
                _host_sync_remote_shell_cmd(host, "test -f $pq && echo ok");
                stderr = devnull,
            ),
            String,
        )
        return strip(result) == "ok"
    catch e
        _rethrow_missing_host_tool(e)
        DistSSHBase._throw_if_nonposix_shell(host, e)
        return false
    end
end

"""Julia `-e` body: fail if Manifest packages are not locatable (instantiate skipped)."""
function _project_deps_probe_expr()::String
    return """
    using Pkg
    missing = String[]
    for (uuid, info) in Pkg.dependencies()
        info.is_tracking_path && continue
        name = String(info.name)
        isempty(name) && continue
        Base.locate_package(Base.PkgId(uuid, name)) === nothing && push!(missing, name)
    end
    if !isempty(missing)
        shown = join(missing[1:min(end, 5)], ", ")
        extra = length(missing) > 5 ? ", …" : ""
        error("not instantiated (" * shown * extra * ")")
    end
    print("ok")
    """
end

"""
Return `nothing` when project deps resolve, else a short error string.
Runs `julia --project=… -e …` (local).
"""
function probe_project_deps(
        project::AbstractString;
        julia_bin::AbstractString = joinpath(Sys.BINDIR, Base.julia_exename()),
    )::Union{Nothing, String}
    proj = canonical_local_path(project)
    _located_project_file(proj) isa String || return "Project.toml not found"
    resolve_pkg_env(proj).manifest isa String || return missing_manifest_message(proj)
    cmd = ignorestatus(
        Cmd(
            [
                String(julia_bin),
                "--project=$proj",
                "--startup-file=no",
                "-e",
                _project_deps_probe_expr(),
            ]
        ),
    )
    err = IOBuffer()
    out = IOBuffer()
    proc = run(pipeline(cmd; stdout = out, stderr = err); wait = true)
    proc.exitcode == 0 && occursin("ok", String(take!(out))) && return nothing
    msg = strip(String(take!(err)))
    isempty(msg) && (msg = strip(String(take!(out))))
    m = match(r"not instantiated \(([^)]+)\)", msg)
    m !== nothing && return "dependencies missing: $(m.captures[1])"
    return isempty(msg) ? "dependency check failed" : first(split(msg, '\n'))
end

"""
Return `nothing` when remote project deps resolve, else a short error string.
"""
function probe_remote_project_deps(
        host::AbstractString,
        remote_path::AbstractString;
        julia_path::AbstractString = "auto",
    )::Union{Nothing, String}
    host_julia = julia_path == "auto" ? detect_julia_path(String(host)) : String(julia_path)
    host_julia === nothing && return "Julia not found"
    pq = _remote_shell_path_word(remote_path)
    jb = _remote_shell_path_word(host_julia)
    expr = _project_deps_probe_expr()
    # Single-quoted -e payload for the remote shell (escape embedded single quotes).
    eq = replace(expr, "'" => "'\\''")
    remote_cmd = "$jb --project=$pq --startup-file=no -e '$eq'"
    err = IOBuffer()
    out = IOBuffer()
    try
        proc = run(
            pipeline(
                ignorestatus(_host_sync_remote_shell_cmd(String(host), remote_cmd));
                stdout = out,
                stderr = err,
            );
            wait = true,
        )
        proc.exitcode == 0 && occursin("ok", String(take!(out))) && return nothing
        msg = strip(String(take!(err)))
        isempty(msg) && (msg = strip(String(take!(out))))
        m = match(r"not instantiated \(([^)]+)\)", msg)
        shown = if m !== nothing
            cap = m.captures[1]
            "dependencies missing: $(cap isa AbstractString ? cap : "")"
        elseif isempty(msg)
            "dependency check failed"
        else
            first(split(msg, '\n'))
        end
        code = proc.exitcode isa Integer ? Int(proc.exitcode) : 1
        return DistSSHBase._append_remote_shell_hint(String(host), code, shown)
    catch e
        return "dependency check failed: $(sprint(showerror, e))"
    end
end

check_git_clean(project::AbstractString) = local_git_clean(project)

function check_prerequisites(
        hosts::Vector{String},
        julia_path::String,
        remote_path::String,
        project::AbstractString;
        path_anchor::AbstractString = project,
        require_clean_git::Bool = false,
        check_code_sync::Bool = true,
        ignore_julia_version::Bool = false,
    )
    kit_println("Checking prerequisites...")
    kit_println()

    all_ok = true
    needs_sync = false
    warnings = SetupWarning[]
    project_path = remote_path
    proj = canonical_local_path(project)
    anchor = canonical_local_path(path_anchor)

    # Local checks
    kit_println("Local:")
    local_tools = _report_local_host_tools!(warnings)
    !local_tools.ssh && (all_ok = false)

    if isfile(joinpath(proj, "Project.toml"))
        ok("Project.toml at $(cli_project_disp(proj, anchor))")
    else
        fail("Project.toml not found")
        all_ok = false
    end

    local_hash = nothing
    if local_tools.git
        if check_git_clean(proj)
            ok("Git working tree clean")
        elseif require_clean_git
            fail("Git has uncommitted changes")
            kit_println("    Fix: git add -A && git commit -m 'your message'")
            all_ok = false
        else
            msg = "Git has uncommitted changes"
            warn(msg)
            push!(warnings, SetupWarning(PARENT_HOST_NAME, :git_dirty, msg))
            kit_println("    Fix: git add -A && git commit -m 'your message'")
        end
        local_hash = get_local_git_hash(proj; short = 12)
        if local_hash === nothing
            # No repo / no HEAD (e.g. DistSSHQueue stage without `.git/`): warn, do not fail.
            msg = "Could not get local git commit"
            warn(msg)
            push!(warnings, SetupWarning(PARENT_HOST_NAME, :git_commit_unknown, msg))
            kit_println("    Skip hash check (not a git commit); instantiate still proceeds")
        else
            ok("Git commit: $local_hash")
        end
    end
    kit_println()

    # Remote checks
    local_tools.ssh || return (ok = false, needs_sync = needs_sync, warnings = warnings)
    for host in hosts
        host_ok = Ref(true)
        _setup_host_span!(host, :running)
        kit_println("$host:")

        ssh_err = probe_setup_ssh(host)
        if ssh_err === nothing
            ok("SSH connection")
        else
            fail("SSH connection failed")
            kit_println("    $ssh_err")
            all_ok = false
            host_ok[] = false
            kit_println()
            _setup_host_span!(host, :fail)
            continue
        end

        # Resolve Julia path per host
        host_julia = julia_path
        if host_julia == "auto"
            try
                host_julia = detect_julia_path(host)
            catch e
                e isa ArgumentError || rethrow()
                fail(e.msg)
                all_ok = false
                host_ok[] = false
                kit_println()
                _setup_host_span!(host, :fail)
                continue
            end
        end

        julia_check = host_julia === nothing ?
            (found = false, version = nothing, mismatch_kind = :none) :
            check_julia(host, String(host_julia))
        checked = host_julia === nothing ? "auto-detect" : String(host_julia)
        if !_report_remote_julia!(host, checked, julia_check, ignore_julia_version, warnings)
            all_ok = false
            host_ok[] = false
        end

        if check_project(host, remote_path)
            ok("Project found at $project_path")
        else
            fail("Project not found at $project_path")
            kit_println("    Fix: --clone $(setup_cli_host_token(host))  (or --ship-tree $(setup_cli_host_token(host)))")
            all_ok = false
            host_ok[] = false
            kit_println()
            _setup_host_span!(host, :fail)
            continue
        end

        if host_julia === nothing || !julia_check.found
            fail("Skipping dependency check (no usable remote Julia)")
            all_ok = false
            host_ok[] = false
        else
            deps_err = probe_remote_project_deps(
                host, remote_path; julia_path = String(host_julia),
            )
            if deps_err === nothing
                ok("Project dependencies resolvable")
            else
                fail(deps_err)
                kit_println("    Fix: julia --project=. -m DistSSHKit setup --instantiate $(setup_cli_host_token(host))")
                all_ok = false
                host_ok[] = false
            end
        end

        if local_tools.git
            remote_hash = get_remote_git_hash(host, remote_path; short = 12)
            if remote_hash === nothing
                msg = "Could not get remote git commit"
                warn(msg)
                push!(warnings, SetupWarning(String(host), :git_commit_unknown, msg))
                needs_sync = true
            elseif local_hash === nothing
                msg = "Git commit not comparable (no local commit)"
                warn(msg)
                push!(warnings, SetupWarning(String(host), :git_commit_unknown, msg))
                needs_sync = true
            elseif remote_hash == local_hash
                ok("Git commit matches ($remote_hash)")
            else
                needs_sync = true
                if check_code_sync
                    fail("Git commit differs (local: $local_hash, remote: $remote_hash)")
                    kit_println("    Fix: --pull or --sync to update remote")
                    all_ok = false
                    host_ok[] = false
                else
                    msg = "Git commit differs (local: $local_hash, remote: $remote_hash)"
                    warn(msg)
                    push!(warnings, SetupWarning(String(host), :git_commit_differs, msg))
                    kit_println("    Will be synced by this operation")
                end
            end
        end

        kit_println()
        _setup_host_span!(host, host_ok[] ? :ok : :fail)
    end

    return (ok = all_ok, needs_sync = needs_sync, warnings = warnings)
end
