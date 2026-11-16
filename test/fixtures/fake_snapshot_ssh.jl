#!/usr/bin/env julia
# Test double for snapshot-selection probes (`DISTSSH_TEST_SSH`).
# Runs `__DSR_SNAP_COMPLETE__` / `__DSR_SNAP_GIT__` locally; other commands stay short.

function _fake_ssh_host_script()::Tuple{String, String}
    args = String.(ARGS)
    idx = findfirst(==("--"), args)
    if idx !== nothing && length(args) >= idx + 2
        return args[idx + 1], args[idx + 2]
    end
    host = length(args) >= 1 ? args[1] : ""
    script = length(args) >= 2 ? args[2] : ""
    return host, script
end

host, script = _fake_ssh_host_script()
ready = strip(get(ENV, "GO_SLOT_SSH_READY", ""))
if !isempty(ready) &&
        (
        occursin("go.exitcode", script) ||
            any(s -> occursin("go.exitcode", s), ARGS)
    )
    open(ready, "w") do io
        println(io, getpid())
    end
end
logical = strip(get(ENV, "DISTSSH_TEST_SSH_LOGICAL_ROOT", ""))
host_roots = strip(get(ENV, "DISTSSH_TEST_SSH_HOST_ROOTS", ""))
if !isempty(logical) && !isempty(host_roots) && !isempty(host)
    host_fs = joinpath(host_roots, host)
    script = replace(script, logical => host_fs)
end
logp = get(ENV, "DISTSSH_TEST_SSH_LOG", "")
if !isempty(logp)
    open(logp, "a") do io
        println(io, "HOST ", host)
        println(io, script)
        println(io, "---")
    end
end

if get(ENV, "DISTSSH_TEST_SSH_FAIL", "") == "1"
    println(stderr, "Permission denied (publickey).")
    exit(255)
end
if occursin("print(joinpath(Sys.BINDIR", script) && occursin("julia", script)
    println(joinpath(Sys.BINDIR, Base.julia_exename()))
    exit(0)
end
if occursin("--version", script) && occursin("julia", script)
    println("julia version 1.10.10")
    exit(0)
end

if occursin("__DSR_POSIX_OK_", script) && occursin("case x in x)", script)
    m = match(r"__DSR_POSIX_OK_[0-9a-fA-F]+__", script)
    m === nothing && exit(1)
    println(m.match)
    exit(0)
end
if strip(script) == "echo \$SHELL"
    println("/bin/sh")
    exit(0)
end
if script == "cd -P ~ && pwd -P" || script == "cd ~ && pwd"
    println(get(ENV, "DISTSSH_TEST_REMOTE_HOME", "/home/distsshkit"))
    exit(0)
end
if occursin("__DSR_SNAP_COMPLETE__", script) || occursin("__DSR_SNAP_GIT__", script)
    cmd = run(pipeline(ignorestatus(`sh -c $script`); stdout = stdout, stderr = stderr); wait = true)
    exit(cmd.exitcode)
end
if occursin("go.exitcode", script) &&
        (occursin("go-handshake", script) || occursin("DISTSSH_GO_HS", script))
    function _posix_single_quote(s::AbstractString)::String
        return "'" * replace(String(s), "'" => "'\"'\"'") * "'"
    end
    act_proj = strip(get(ENV, "DISTSSH_TEST_ACTIVE_PROJECT", ""))
    if !isempty(act_proj)
        script = replace(script, "--project=." => "--project=$(_posix_single_quote(act_proj))")
    end
    ctl_lp = strip(get(ENV, "DISTSSH_TEST_CONTROLLER_LOAD_PATH", ""))
    if !isempty(ctl_lp)
        script = replace(
            script,
            "JULIA_LOAD_PATH='@:@stdlib'" => "JULIA_LOAD_PATH=$(_posix_single_quote(ctl_lp))")
    end
    env = copy(ENV)
    depot = strip(get(ENV, "JULIA_DEPOT_PATH", ""))
    !isempty(depot) && (env["JULIA_DEPOT_PATH"] = depot)
    cmd = run(
        pipeline(
            ignorestatus(setenv(`sh -c $script`, env));
            stdin = stdin,
            stdout = stdout,
            stderr = stderr);
        wait = true)
    exit(cmd.exitcode)
end
# Absolute deploy roots do not need further path resolve.
if occursin("pwd -P", script) || occursin("printf '%s\\n'", script)
    # Fallback: try to run path-resolve scripts that print a path.
    cmd = run(pipeline(ignorestatus(`sh -c $script`); stdout = stdout, stderr = stderr); wait = true)
    exit(cmd.exitcode)
end
if occursin(".distssh/deploy.toml", script) && occursin("cat", script)
    cmd = run(pipeline(ignorestatus(`sh -c $script`); stdout = stdout, stderr = stderr); wait = true)
    exit(cmd.exitcode)
end
exit(0)
