#!/usr/bin/env julia
# Opt-in SSH E2E for DistSSHHeartbeat. Not part of ordinary Pkg.test().
#
#   testenv/docker-ssh/scripts/up.sh
#   DISTSSH_SSH_E2E=1 julia --project=lib/DistSSHHeartbeat lib/DistSSHHeartbeat/test/e2e.jl
#
# SIGKILL detached-drive reap (Distributed EOF exit 1, not heartbeat 75) lives in
# test/e2e.jl. This file is SIGSTOP timing / heartbeat exit 75 (#148).

using Random
using Test
using Distributed
using DistSSHBase
using DistSSHHeartbeat

if get(ENV, "DISTSSH_SSH_E2E", "") != "1" && abspath(PROGRAM_FILE) == @__FILE__
    @info "Skipping SSH E2E (set DISTSSH_SSH_E2E=1 to enable)"
    exit(0)
end

const _ssh_config = abspath(
    joinpath(@__DIR__, "..", "..", "..", "testenv", "docker-ssh", ".generated", "ssh_config"),
)
isfile(_ssh_config) ||
    error("docker-ssh not ready: missing $(_ssh_config). Run testenv/docker-ssh/scripts/up.sh")

const _host = "child-1"
const _INTERVAL_SEC = 1.0
const _DEADLINE_SEC = 5.0
const _HEARTBEAT_EXIT_CODE = DistSSHHeartbeat.HEARTBEAT_EXIT_CODE
const _GONE_TIMEOUT_SEC = _DEADLINE_SEC + 2 * _INTERVAL_SEC + 10.0 + 8.0
const _WORKER_PGREP_PATTERN = "[j]ulia.*--worker"
const _LIVENESS_AFTER_STOP_SEC = 2.0

function _fail(msg::AbstractString)
    error(msg)
end

function _remote_pid_alive(host::AbstractString, pid::Int)::Bool
    pid > 0 || return false
    proc_q = DistSSHBase._remote_shell_path_word("/proc/$pid")
    code, _ = DistSSHBase._remote_shell_status(String(host), "test -d $proc_q")
    return code == 0
end

function _read_remote_exit_code(host::AbstractString, path::AbstractString)::Union{Nothing, Int}
    pq = DistSSHBase._remote_shell_path_word(path)
    code, out = DistSSHBase._remote_shell_status(String(host), "cat $pq 2>/dev/null || true")
    code == 0 || return nothing
    lines = split(strip(out); keepempty = true)
    isempty(lines) && return nothing
    line = strip(first(lines))
    isempty(line) && return nothing
    parsed = tryparse(Int, line)
    return parsed
end

function _install_worker_wrapper!(host::AbstractString, tag::AbstractString, julia::AbstractString)
    wrap = "/tmp/hb_wrap_$(tag).sh"
    exitf = "/tmp/hb_exit_$(tag)"
    occursin('\'', julia) && _fail("remote julia path contains single quote")
    wrap_q = DistSSHBase._remote_shell_path_word(wrap)
    exit_q = DistSSHBase._remote_shell_path_word(exitf)
    exitf_q = DistSSHBase._remote_sh_quote(exitf)
    julia_q = DistSSHBase._remote_sh_quote(julia)
    script = """
    set -eu
    {
    echo '#!/bin/sh'
    echo "EXITF=$exitf_q"
    echo "JULIA=$julia_q"
    echo '"\$JULIA" "\$@"'
    echo 'status=\$?'
    echo 'printf "%s\\n" "\$status" > "\$EXITF"'
    echo 'exit "\$status"'
    } > $wrap_q
    chmod +x $wrap_q
    rm -f $exit_q
    """
    code, err = DistSSHBase._remote_shell_status(String(host), script)
    code == 0 || _fail("could not install worker wrapper on $host: $err")
    return wrap, exitf
end

function _master_script_contents(
        ready_path::AbstractString,
        wrap_remote::AbstractString,
        ssh_opts::AbstractString,
    )::String
    ready = repr(String(ready_path))
    wrap = repr(String(wrap_remote))
    interval = repr(_INTERVAL_SEC)
    deadline = repr(_DEADLINE_SEC)
    host = repr(_host)
    opts = repr(String(ssh_opts))
    return """
    using Distributed
    using DistSSHBase
    using DistSSHHeartbeat

    ENV["DISTRIBUTED_SSH_OPTS"] = $opts
    const _ready = $ready
    const _host = $host
    const _wrap = $wrap
    const _interval = $interval
    const _deadline = $deadline

    withenv(
        "DISTRIBUTED_HEARTBEAT_INTERVAL_SEC" => string(_interval),
        "DISTRIBUTED_HEARTBEAT_DEADLINE_SEC" => string(_deadline),
    ) do
        machine = string(DistSSHBase.ssh_addprocs_machine(_host), " 127.0.0.1")
        sshflags = Cmd(DistSSHBase.ssh_opts())
        tunnel = get(ENV, "DISTSSH_SSH_TUNNEL", "1") != "0"
        addprocs([machine]; exename = _wrap, sshflags = sshflags, tunnel = tunnel)
        w = workers()[end]
        try
            DistSSHHeartbeat.install_and_start_heartbeat!([w]; interval = _interval, deadline = _deadline)
            remotecall_fetch(() -> myid(), w) == w || error("worker ping failed before STOP")
            worker_os_pid = remotecall_fetch(() -> getpid(), w)
            open(_ready, "w") do io
                println(io, getpid())
                println(io, w)
                println(io, worker_os_pid)
            end
            while true
                sleep(3600)
            end
        catch e
            open(_ready, "w") do io
                println(io, "error")
                println(io, sprint(showerror, e))
            end
            rethrow()
        end
    end
    """
end

function _julia_cmd_for_master(script_path::AbstractString)
    proj = normpath(joinpath(@__DIR__, ".."))
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    return `$julia --project=$proj --startup-file=no $script_path`
end

@testset "DistSSHHeartbeat SSH" verbose = true begin
    @testset "ssh reachable" begin
        ssh = Sys.which("ssh")
        @test ssh !== nothing
        proc = run(
            pipeline(
                `$ssh -F $(_ssh_config) -o BatchMode=yes -o ConnectTimeout=5 child-1 true`;
                stdout = devnull, stderr = devnull
            );
            wait = false,
        )
        wait(proc)
        @test success(proc)
    end

    withenv("DISTRIBUTED_SSH_OPTS" => "-F $(_ssh_config) -o RequestTTY=no") do
        @testset "SIGSTOP master reaps worker with heartbeat exit 75" begin
            tag = bytes2hex(rand(UInt8, 8))
            remote_julia = DistSSHBase.resolve_remote_julia(_host, "auto")
            remote_julia isa AbstractString ||
                _fail("could not resolve remote julia on $_host")
            wrap_path = exit_path = nothing
            master_proc = nothing
            master_script = ready_path = nothing
            master_pid = Ref(0)
            worker_os_pid = Ref(0)
            try
                wrap_path, exit_path = _install_worker_wrapper!(_host, tag, remote_julia)
                run_dir = mktempdir()
                ready_path = joinpath(run_dir, "ready.txt")
                master_script = joinpath(run_dir, "master.jl")
                ssh_opts = "-F $(_ssh_config) -o RequestTTY=no"
                write(master_script, _master_script_contents(ready_path, wrap_path, ssh_opts))
                master_stderr = IOBuffer()
                master_proc = withenv("DISTRIBUTED_SSH_OPTS" => ssh_opts) do
                    return run(
                        pipeline(
                            _julia_cmd_for_master(master_script);
                            stdout = devnull,
                            stderr = master_stderr,
                        );
                        wait = false,
                    )
                end
                worker_id = Ref(0)
                t0 = time()
                while (time() - t0) < 120
                    if isfile(ready_path)
                        lines = filter(!isempty, strip.(split(read(ready_path, String), '\n')))
                        if !isempty(lines)
                            if lines[1] == "error"
                                length(lines) >= 2 ||
                                    _fail("master error marker without message")
                                _fail("master failed before ready: $(join(lines[2:end], '\n'))")
                            elseif length(lines) >= 3
                                master_pid[] = parse(Int, lines[1])
                                worker_id[] = parse(Int, lines[2])
                                worker_os_pid[] = parse(Int, lines[3])
                                break
                            end
                        end
                    end
                    process_running(master_proc) || break
                    sleep(0.2)
                end
                master_pid[] > 0 ||
                    _fail(
                    "master never became ready " *
                        "(ready=$(isfile(ready_path) ? read(ready_path, String) : ""); " *
                        "stderr=$(String(take!(master_stderr))))",
                )
                worker_id[] > 0 || _fail("invalid worker id from master")
                worker_os_pid[] > 0 || _fail("invalid worker os pid from master")
                _remote_pid_alive(_host, worker_os_pid[]) ||
                    _fail("worker os pid $(worker_os_pid[]) not alive on $_host before STOP")

                sleep(_INTERVAL_SEC + 0.5)
                run(`kill -STOP $(master_pid[])`)
                t_stop = time()

                sleep(_LIVENESS_AFTER_STOP_SEC)
                @test _remote_pid_alive(_host, worker_os_pid[])

                gone = false
                t1 = time()
                while (time() - t1) < _GONE_TIMEOUT_SEC
                    if !_remote_pid_alive(_host, worker_os_pid[])
                        gone = true
                        break
                    end
                    sleep(0.25)
                end
                gone || _fail(
                    "worker os pid $(worker_os_pid[]) still alive after STOP + " *
                        "$(round(time() - t_stop; digits = 1))s " *
                        "(timeout=$(_GONE_TIMEOUT_SEC)s)",
                )
                @test gone

                exit_code = nothing
                t2 = time()
                while (time() - t2) < 5.0
                    exit_code = _read_remote_exit_code(_host, exit_path)
                    exit_code !== nothing && break
                    sleep(0.2)
                end
                exit_code === nothing &&
                    _fail("missing exit code file $exit_path on $_host after worker exit")
                @test exit_code == _HEARTBEAT_EXIT_CODE
            finally
                if master_proc !== nothing
                    try
                        master_pid[] > 0 && run(`kill -CONT $(master_pid[])`; wait = false)
                    catch
                    end
                    try
                        master_pid[] > 0 && run(`kill -KILL $(master_pid[])`; wait = false)
                    catch
                    end
                    try
                        wait(master_proc)
                    catch
                    end
                end
                if exit_path !== nothing
                    pq = DistSSHBase._remote_shell_path_word(exit_path)
                    try
                        DistSSHBase._remote_shell_status(_host, "rm -f $pq")
                    catch
                    end
                end
                if wrap_path !== nothing
                    pq = DistSSHBase._remote_shell_path_word(wrap_path)
                    try
                        DistSSHBase._remote_shell_status(_host, "rm -f $pq")
                    catch
                    end
                end
                try
                    pat_q = DistSSHBase._remote_sh_quote(_WORKER_PGREP_PATTERN)
                    DistSSHBase._remote_shell_status(_host, "pkill -f $pat_q || true")
                catch
                end
                master_script !== nothing && isfile(master_script) && rm(master_script; force = true)
                ready_path !== nothing && ispath(dirname(ready_path)) && rm(dirname(ready_path); force = true, recursive = true)
            end
        end
    end
end
