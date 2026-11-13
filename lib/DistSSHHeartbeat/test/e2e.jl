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

"""`DISTRIBUTED_SSH_OPTS` for this E2E; config path is shell-quoted for `Base.shell_split`."""
function _distributed_ssh_opts(config_path::AbstractString = _ssh_config)::String
    cfg_q = DistSSHBase._remote_sh_quote(abspath(String(config_path)))
    return "-F $cfg_q -o RequestTTY=no"
end

const _host = "child-1"
const _INTERVAL_SEC = 1.0
const _DEADLINE_SEC = 5.0
const _HEARTBEAT_EXIT_CODE = DistSSHHeartbeat.HEARTBEAT_EXIT_CODE
const _GONE_TIMEOUT_SEC = _DEADLINE_SEC + 2 * _INTERVAL_SEC + 10.0 + 8.0
const _WORKER_PGREP_PATTERN = "[j]ulia.*--worker"
const _LIVENESS_AFTER_STOP_SEC = 2.0
# Brief SIGSTOP for negative control: must stay well under `_DEADLINE_SEC`.
const _BRIEF_STOP_SEC = 1.0
const _BRIEF_STOP_WALL_MAX_SEC = _DEADLINE_SEC - 2 * _INTERVAL_SEC
const _POST_CONT_SETTLE_SEC = _INTERVAL_SEC + 1.0
const _NEGATIVE_SURVIVE_AFTER_CONT_SEC = _DEADLINE_SEC + 2 * _INTERVAL_SEC + 3.0
const _PROBE_TIMEOUT_SEC = 30.0
# Worker-clock slack for SSH + wrapper + scheduler (see exit-delay assertion below).
const _TIMING_SLACK_SEC = 3.0
const _EXIT_DELAY_MIN_SEC = _DEADLINE_SEC - _INTERVAL_SEC - 0.5
const _EXIT_DELAY_MAX_SEC = _DEADLINE_SEC + 2 * _INTERVAL_SEC + 10.0 + _TIMING_SLACK_SEC

function _fail(msg::AbstractString)
    error(msg)
end

function _stderr_snippet(master_stderr::IOBuffer; max_chars::Int = 4000)::String
    saved = position(master_stderr)
    seekstart(master_stderr)
    s = String(read(master_stderr))
    seek(master_stderr, saved)
    return length(s) > max_chars ? s[(end - max_chars + 1):end] : s
end

function _fail_with_stderr(msg::AbstractString, master_stderr::IOBuffer)
    return _fail(msg * " stderr=$(repr(_stderr_snippet(master_stderr)))")
end

function _remote_pid_alive(host::AbstractString, pid::Int)::Bool
    pid > 0 || return false
    proc_q = DistSSHBase._remote_shell_path_word("/proc/$pid")
    code, _ = DistSSHBase._remote_shell_status(String(host), "test -d $proc_q")
    return code == 0
end

function _remote_worker_timestamp(host::AbstractString)::Union{Nothing, Float64}
    code, out = DistSSHBase._remote_shell_status(String(host), "date +%s.%N")
    code == 0 || return nothing
    line = strip(String(out))
    isempty(line) && return nothing
    return tryparse(Float64, line)
end

function _log_worker_process_tree!(host::AbstractString, worker_os_pid::Int)
    pat_q = DistSSHBase._remote_sh_quote(_WORKER_PGREP_PATTERN)
    _, pgrep_af = DistSSHBase._remote_shell_status(String(host), "pgrep -af -f $pat_q || true")
    println(stderr, "[HB_E2E] worker_os_pid=$worker_os_pid pgrep -af: ", strip(String(pgrep_af)))
    if worker_os_pid > 0
        pid_q = DistSSHBase._remote_sh_quote(string(worker_os_pid))
        _, ps_out = DistSSHBase._remote_shell_status(
            String(host),
            "ps -o pid=,ppid=,args= -p $pid_q 2>&1; " *
                "ps -o pid=,ppid=,args= -p \$(ps -o ppid= -p $pid_q 2>/dev/null) 2>&1 || true",
        )
        println(stderr, "[HB_E2E] worker tree ps: ", strip(String(ps_out)))
    end
    flush(stderr)
    return nothing
end

function _read_remote_exit_record(
        host::AbstractString,
        path::AbstractString,
    )::Tuple{Union{Nothing, Int}, Union{Nothing, Float64}}
    pq = DistSSHBase._remote_shell_path_word(path)
    code, out = DistSSHBase._remote_shell_status(String(host), "cat $pq 2>/dev/null || true")
    code == 0 || return nothing, nothing
    lines = split(strip(out); keepempty = true)
    length(lines) < 1 && return nothing, nothing
    exit_line = strip(first(lines))
    isempty(exit_line) && return nothing, nothing
    exit_code = tryparse(Int, exit_line)
    exit_ts = nothing
    if length(lines) >= 2
        exit_ts = tryparse(Float64, strip(lines[2]))
    end
    return exit_code, exit_ts
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
    echo 'ts=\$(date +%s.%N); printf "%s\\n%s\\n" "\$status" "\$ts" > "\$EXITF"'
    echo 'exit "\$status"'
    } > $wrap_q
    chmod +x $wrap_q
    rm -f $exit_q
    """
    code, err = DistSSHBase._remote_shell_status(String(host), script)
    code == 0 || _fail("could not install worker wrapper on $host: $err")
    return wrap, exitf
end

function _kill_worker_and_wrapper!(host::AbstractString, worker_os_pid::Int)
    worker_os_pid <= 0 && return nothing
    pid_q = DistSSHBase._remote_sh_quote(string(worker_os_pid))
    script = """
    wrapper_ppid=\$(ps -o ppid= -p $pid_q 2>/dev/null | tr -d ' ')
    kill -9 $pid_q 2>/dev/null || true
    if [ -n "\$wrapper_ppid" ] && [ "\$wrapper_ppid" -gt 1 ]; then
      kill -9 "\$wrapper_ppid" 2>/dev/null || true
    fi
    """
    DistSSHBase._remote_shell_status(String(host), script)
    return nothing
end

function _master_script_contents(
        ready_path::AbstractString,
        probe_req_path::AbstractString,
        probe_ok_path::AbstractString,
        wrap_remote::AbstractString,
        ssh_opts::AbstractString,
    )::String
    ready = repr(String(ready_path))
    probe_req = repr(String(probe_req_path))
    probe_ok = repr(String(probe_ok_path))
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
    const _probe_req = $probe_req
    const _probe_ok = $probe_ok
    const _host = $host
    const _wrap = $wrap
    const _interval = $interval
    const _deadline = $deadline

    function _publish_lines_atomic(path, lines)
        dir = dirname(path)
        part = joinpath(dir, ".pub.\$(getpid()).tmp")
        open(part, "w") do io
            for ln in lines
                println(io, ln)
            end
        end
        mv(part, path; force = true)
        return nothing
    end

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
            _publish_lines_atomic(_ready, [string(getpid()), string(w), string(worker_os_pid)])
            while true
                if isfile(_probe_req)
                    rm(_probe_req; force = true)
                    remotecall_fetch(() -> myid(), w) == w || error("worker ping failed on probe")
                    _publish_lines_atomic(_probe_ok, ["ok", string(w)])
                end
                sleep(0.2)
            end
        catch e
            _publish_lines_atomic(_ready, ["error", sprint(showerror, e)])
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

mutable struct _HeartbeatE2ECtx
    wrap_path::Union{String, Nothing}
    exit_path::Union{String, Nothing}
    master_proc::Union{Base.Process, Nothing}
    master_script::Union{String, Nothing}
    run_dir::Union{String, Nothing}
    ready_path::Union{String, Nothing}
    probe_req_path::Union{String, Nothing}
    probe_ok_path::Union{String, Nothing}
    master_pid::Ref{Int}
    worker_id::Ref{Int}
    worker_os_pid::Ref{Int}
    master_stderr::IOBuffer
    master_was_stopped::Bool
end

function _wait_master_ready!(
        ready_path::AbstractString,
        master_proc::Base.Process,
        master_stderr::IOBuffer,
        master_pid::Ref{Int},
        worker_id::Ref{Int},
        worker_os_pid::Ref{Int};
        timeout_sec::Real = 120,
    )
    t0 = time()
    while (time() - t0) < timeout_sec
        if isfile(ready_path)
            lines = filter(!isempty, strip.(split(read(ready_path, String), '\n')))
            if !isempty(lines)
                if lines[1] == "error"
                    length(lines) >= 2 || _fail("master error marker without message")
                    _fail_with_stderr(
                        "master failed before ready: $(join(lines[2:end], '\n')) ",
                        master_stderr,
                    )
                elseif length(lines) >= 3
                    master_pid[] = parse(Int, lines[1])
                    worker_id[] = parse(Int, lines[2])
                    worker_os_pid[] = parse(Int, lines[3])
                    return nothing
                end
            end
        end
        process_running(master_proc) || break
        sleep(0.2)
    end
    master_pid[] > 0 ||
        _fail_with_stderr(
        "master never became ready " *
            "(ready=$(isfile(ready_path) ? read(ready_path, String) : ""); ",
        master_stderr,
    )
    return nothing
end

function _heartbeat_e2e_begin!(; label::AbstractString = "STOP")::_HeartbeatE2ECtx
    tag = bytes2hex(rand(UInt8, 8))
    remote_julia = DistSSHBase.resolve_remote_julia(_host, "auto")
    remote_julia isa AbstractString || _fail("could not resolve remote julia on $_host")
    master_stderr = IOBuffer()
    master_pid = Ref(0)
    worker_id = Ref(0)
    worker_os_pid = Ref(0)
    wrap_path, exit_path = _install_worker_wrapper!(_host, tag, remote_julia)
    run_dir = mktempdir()
    ready_path = joinpath(run_dir, "ready.txt")
    probe_req_path = joinpath(run_dir, "probe.req")
    probe_ok_path = joinpath(run_dir, "probe.ok")
    master_script = joinpath(run_dir, "master.jl")
    ssh_opts = _distributed_ssh_opts()
    write(
        master_script,
        _master_script_contents(ready_path, probe_req_path, probe_ok_path, wrap_path, ssh_opts),
    )
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
    _wait_master_ready!(
        ready_path,
        master_proc,
        master_stderr,
        master_pid,
        worker_id,
        worker_os_pid,
    )
    process_running(master_proc) ||
        _fail_with_stderr("master exited before $label ", master_stderr)
    worker_id[] > 0 || _fail("invalid worker id from master")
    worker_os_pid[] > 0 || _fail("invalid worker os pid from master")
    _remote_pid_alive(_host, worker_os_pid[]) ||
        _fail("worker os pid $(worker_os_pid[]) not alive on $_host before $label")
    return _HeartbeatE2ECtx(
        wrap_path,
        exit_path,
        master_proc,
        master_script,
        run_dir,
        ready_path,
        probe_req_path,
        probe_ok_path,
        master_pid,
        worker_id,
        worker_os_pid,
        master_stderr,
        false,
    )
end

function _request_master_probe!(ctx::_HeartbeatE2ECtx)
    isfile(ctx.probe_ok_path) && rm(ctx.probe_ok_path; force = true)
    open(ctx.probe_req_path, "w") do io
        println(io, "go")
    end
    t0 = time()
    while (time() - t0) < _PROBE_TIMEOUT_SEC
        if isfile(ctx.probe_ok_path)
            lines = filter(!isempty, strip.(split(read(ctx.probe_ok_path, String), '\n')))
            if length(lines) >= 1 && lines[1] == "ok"
                return lines
            end
        end
        sleep(0.2)
    end
    return _fail_with_stderr(
        "master probe timed out (probe_ok=$(isfile(ctx.probe_ok_path) ? read(ctx.probe_ok_path, String) : "")); ",
        ctx.master_stderr,
    )
end

function _sigcont_master!(master_proc::Base.Process)
    process_running(master_proc) || return nothing
    run(`kill -CONT $(getpid(master_proc))`)
    return nothing
end

function _heartbeat_e2e_cleanup!(ctx::_HeartbeatE2ECtx)
    if ctx.master_proc !== nothing
        try
            ctx.master_was_stopped && _sigcont_master!(ctx.master_proc)
        catch
        end
        try
            process_running(ctx.master_proc) && kill(ctx.master_proc, Base.SIGKILL)
        catch
        end
        try
            wait(ctx.master_proc)
        catch
        end
    end
    if ctx.exit_path !== nothing
        pq = DistSSHBase._remote_shell_path_word(ctx.exit_path)
        try
            DistSSHBase._remote_shell_status(_host, "rm -f $pq")
        catch
        end
    end
    if ctx.wrap_path !== nothing
        pq = DistSSHBase._remote_shell_path_word(ctx.wrap_path)
        try
            DistSSHBase._remote_shell_status(_host, "rm -f $pq")
        catch
        end
    end
    try
        _kill_worker_and_wrapper!(_host, ctx.worker_os_pid[])
    catch
    end
    ctx.master_script !== nothing && isfile(ctx.master_script) && rm(ctx.master_script; force = true)
    ctx.run_dir !== nothing && ispath(ctx.run_dir) && rm(ctx.run_dir; force = true, recursive = true)
    return nothing
end

function _master_os_pid(ctx::_HeartbeatE2ECtx)
    ctx.master_proc === nothing && _fail("no master process")
    return getpid(ctx.master_proc)
end

function _sigstop_cont_negative_e2e_case!()
    ctx = _heartbeat_e2e_begin!(; label = "brief STOP")
    try
        sleep(_INTERVAL_SEC + 0.5)
        master_os_pid = _master_os_pid(ctx)
        t_stop0 = time()
        run(`kill -STOP $master_os_pid`)
        ctx.master_was_stopped = true

        sleep(_BRIEF_STOP_SEC)
        @test _remote_pid_alive(_host, ctx.worker_os_pid[])

        run(`kill -CONT $master_os_pid`)
        ctx.master_was_stopped = false
        stop_wall = time() - t_stop0
        println(
            stderr,
            "[HB_E2E] brief STOP wall time: $(round(stop_wall; digits = 3))s " *
                "(max $_BRIEF_STOP_WALL_MAX_SEC s)",
        )
        flush(stderr)
        stop_wall <= _BRIEF_STOP_WALL_MAX_SEC ||
            _fail("brief STOP wall time $(round(stop_wall; digits = 3))s exceeds $_BRIEF_STOP_WALL_MAX_SEC s")

        sleep(_POST_CONT_SETTLE_SEC)
        probe_lines = _request_master_probe!(ctx)
        @test length(probe_lines) >= 2
        @test parse(Int, probe_lines[2]) == ctx.worker_id[]

        sleep(_NEGATIVE_SURVIVE_AFTER_CONT_SEC)
        @test _remote_pid_alive(_host, ctx.worker_os_pid[])
        exit_code, _ = _read_remote_exit_record(_host, ctx.exit_path)
        @test exit_code !== _HEARTBEAT_EXIT_CODE
    finally
        _heartbeat_e2e_cleanup!(ctx)
    end
    return nothing
end

function _sigstop_heartbeat_e2e_case!()
    ctx = _heartbeat_e2e_begin!(; label = "STOP")
    try
        _log_worker_process_tree!(_host, ctx.worker_os_pid[])

        sleep(_INTERVAL_SEC + 0.5)
        t_stop_worker = _remote_worker_timestamp(_host)
        t_stop_worker === nothing &&
            _fail("could not read worker clock before STOP on $_host")
        master_os_pid = _master_os_pid(ctx)
        run(`kill -STOP $master_os_pid`)
        ctx.master_was_stopped = true

        sleep(_LIVENESS_AFTER_STOP_SEC)
        @test _remote_pid_alive(_host, ctx.worker_os_pid[])

        gone = false
        t1 = time()
        while (time() - t1) < _GONE_TIMEOUT_SEC
            if !_remote_pid_alive(_host, ctx.worker_os_pid[])
                gone = true
                break
            end
            sleep(0.25)
        end
        gone || _fail_with_stderr(
            "worker os pid $(ctx.worker_os_pid[]) still alive after STOP " *
                "(timeout=$(_GONE_TIMEOUT_SEC)s controller_elapsed=$(round(time() - t1; digits = 1))s); ",
            ctx.master_stderr,
        )
        @test gone

        exit_code = nothing
        exit_ts = nothing
        t2 = time()
        while (time() - t2) < 5.0
            exit_code, exit_ts = _read_remote_exit_record(_host, ctx.exit_path)
            exit_code !== nothing && exit_ts !== nothing && break
            sleep(0.2)
        end
        (exit_code === nothing || exit_ts === nothing) && _fail_with_stderr(
            "missing exit record on $(ctx.exit_path) (exit_code=$(repr(exit_code)) exit_ts=$(repr(exit_ts))); ",
            ctx.master_stderr,
        )
        @test exit_code == _HEARTBEAT_EXIT_CODE

        exit_delay = exit_ts - t_stop_worker
        println(
            stderr, "[HB_E2E] exit delay (worker clock STOP→exit): $(round(exit_delay; digits = 3))s " *
                "(allowed [$(_EXIT_DELAY_MIN_SEC), $(_EXIT_DELAY_MAX_SEC)])"
        )
        flush(stderr)
        if exit_delay < _EXIT_DELAY_MIN_SEC || exit_delay > _EXIT_DELAY_MAX_SEC
            _fail_with_stderr(
                "exit delay $(round(exit_delay; digits = 3))s outside " *
                    "[$(_EXIT_DELAY_MIN_SEC), $(_EXIT_DELAY_MAX_SEC)]; ",
                ctx.master_stderr,
            )
        end
        @test _EXIT_DELAY_MIN_SEC <= exit_delay <= _EXIT_DELAY_MAX_SEC
    finally
        _heartbeat_e2e_cleanup!(ctx)
    end
    return nothing
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

    @testset "DISTRIBUTED_SSH_OPTS shell_split" begin
        spaced_cfg = joinpath(mktempdir(), "ssh config with spaces")
        opts = _distributed_ssh_opts(spaced_cfg)
        split = Base.shell_split(opts)
        fidx = findfirst(==("-F"), split)
        @test fidx !== nothing
        @test split[fidx + 1] == abspath(spaced_cfg)
        withenv("DISTRIBUTED_SSH_OPTS" => opts) do
            @test DistSSHBase.ssh_opts() == ["-F", abspath(spaced_cfg), "-o", "RequestTTY=no"]
        end
    end

    withenv("DISTRIBUTED_SSH_OPTS" => _distributed_ssh_opts()) do
        n = try
            max(1, parse(Int, strip(get(ENV, "DISTSSH_HEARTBEAT_E2E_N", "1"))))
        catch
            1
        end
        @testset "SIGSTOP brief pause does not reap worker (negative control)" begin
            _sigstop_cont_negative_e2e_case!()
        end
        for iter in 1:n
            @testset "SIGSTOP master reaps worker with heartbeat exit 75 (iter $iter/$n)" begin
                _sigstop_heartbeat_e2e_case!()
            end
        end
    end
end
