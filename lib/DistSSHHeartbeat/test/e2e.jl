#!/usr/bin/env julia
# Opt-in SSH E2E for DistSSHHeartbeat. Not part of ordinary Pkg.test().
#
#   testenv/docker-ssh/scripts/up.sh
#   DISTSSH_SSH_E2E=1 julia --project=lib/DistSSHHeartbeat lib/DistSSHHeartbeat/test/e2e.jl
#
# SIGKILL detached-drive reap (Distributed EOF exit 1, not heartbeat 75) lives in
# test/e2e.jl. This file is SIGSTOP timing / heartbeat exit 75 (#148).

using Dates
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
const _HB_EXIT75_NEEDLE = "DistSSHHeartbeat: master did not answer within the deadline"
const _TRACE_DIR = "/tmp"
const _TRACE_PREFIX = "hb_e2e_strace"

function _fail(msg::AbstractString)
    error(msg)
end

function _hb_diag_log(msg::AbstractString)
    println(stderr, "[HB_E2E_DIAG $(Dates.format(now(), dateformat"HH:MM:SS.sss"))] ", msg)
    flush(stderr)
    return nothing
end

function _remote_cat(host::AbstractString, path::AbstractString)::String
    pq = DistSSHBase._remote_shell_path_word(path)
    code, out = DistSSHBase._remote_shell_status(String(host), "cat $pq 2>/dev/null || true")
    code == 0 || return ""
    return String(out)
end

function _remote_ls(host::AbstractString, path::AbstractString)::String
    pq = DistSSHBase._remote_shell_path_word(path)
    code, out = DistSSHBase._remote_shell_status(String(host), "ls -la $pq 2>&1 || true")
    return code == 0 ? String(out) : ""
end

function _trace_path(pid::Integer)::String
    return "$(_TRACE_DIR)/$(_TRACE_PREFIX).$(pid)"
end

function _worker_julia_pids(host::AbstractString)::Vector{Int}
    pat_q = DistSSHBase._remote_sh_quote(_WORKER_PGREP_PATTERN)
    code, body = DistSSHBase._remote_shell_status(String(host), "pgrep -f $pat_q || true")
    code == 0 || _fail("pgrep failed on $host (exit=$code)")
    return Int[parse(Int, s) for s in split(strip(body); keepempty = false)]
end

function _pid_identity_lines(host::AbstractString, pids::AbstractVector{Int})::String
    isempty(pids) && return "(no pids)"
    pid_csv = join(string.(pids), ",")
    script = """
    for pid in $pid_csv; do
      echo "== pid=\$pid =="
      ps -o pid=,ppid=,stat=,args= -p "\$pid" 2>&1 || echo "ps-missing"
      echo -n "comm="
      cat "/proc/\$pid/comm" 2>/dev/null || echo "?"
      echo -n "exe="
      readlink "/proc/\$pid/exe" 2>/dev/null || echo "?"
    done
    """
    code, out = DistSSHBase._remote_shell_status(String(host), script)
    return code == 0 ? strip(String(out)) : "pid-identity exit=$code"
end

function _log_pgrep_snapshot!(host::AbstractString, label::AbstractString)
    pat_q = DistSSHBase._remote_sh_quote(_WORKER_PGREP_PATTERN)
    _, pgrep_af = DistSSHBase._remote_shell_status(String(host), "pgrep -af -f $pat_q || true")
    pids = _worker_julia_pids(host)
    _hb_diag_log("$label pgrep pids=$pids")
    _hb_diag_log("$label pgrep -af: $(strip(String(pgrep_af)))")
    for line in split(_pid_identity_lines(host, pids), '\n')
        isempty(strip(line)) || _hb_diag_log("$label $line")
    end
    return pids
end

function _remote_file_nonempty(host::AbstractString, path::AbstractString)::Bool
    pq = DistSSHBase._remote_shell_path_word(path)
    code, out = DistSSHBase._remote_shell_status(String(host), "test -s $pq && cat $pq")
    return code == 0 && !isempty(strip(out))
end

function _read_remote_exit_code(host::AbstractString, path::AbstractString)::Union{Nothing, Int}
    pq = DistSSHBase._remote_shell_path_word(path)
    code, out = DistSSHBase._remote_shell_status(String(host), "cat $pq 2>/dev/null || true")
    code == 0 || return nothing
    line = strip(first(split(strip(out); keepempty = true); init = ""))
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
    script = """
    set -eu
    {
    echo '#!/bin/sh'
    echo 'EXITF=$exitf'
    echo 'JULIA=$julia'
    echo '"\$JULIA" "\$@"'
    echo 'status=\$?'
    echo 'printf "%s\n" "\$status" > "\$EXITF"'
    echo 'exit "\$status"'
    } > $wrap_q
    chmod +x $wrap_q
    rm -f $exit_q
    """
    code, err = DistSSHBase._remote_shell_status(String(host), script)
    code == 0 || _fail("could not install worker wrapper on $host: $err")
    return wrap, exitf
end

function _hb_strace_begin!(host::AbstractString, worker_pid::Int)::Tuple{Bool, String}
    worker_pid > 0 || return (false, "invalid worker pid")
    tp = DistSSHBase._remote_shell_path_word(_trace_path(worker_pid))
    tp_pid = DistSSHBase._remote_shell_path_word(_trace_path(worker_pid) * ".strace_pid")
    inner = join(
        [
            "command -v strace >/dev/null",
            "rm -f $tp $tp_pid",
            "nohup sudo -n timeout 120 strace -q -f -tt -e trace=write,writev,exit_group -s 300 -p $worker_pid >> $tp 2>&1 &",
            "echo \$! > $tp_pid",
            "echo started",
        ],
        "; ",
    )
    inner_q = DistSSHBase._remote_sh_quote(inner)
    code, body = DistSSHBase._remote_shell_status(String(host), "bash -lc $inner_q")
    ok = code == 0 && occursin("started", body)
    return (
        ok,
        ok ? strip(String(body)) : "exit=$code body=$(repr(strip(body)))",
    )
end

function _hb_strace_wait_attached!(
        host::AbstractString,
        worker_pid::Int;
        timeout::Real = 30,
    )::Tuple{Bool, String}
    status_path = DistSSHBase._remote_shell_path_word("/proc/$(worker_pid)/status")
    t0 = time()
    while (time() - t0) < timeout
        code, tp = DistSSHBase._remote_shell_status(
            String(host),
            "awk '/^TracerPid:/ {print \$2}' $status_path 2>/dev/null",
        )
        tp = strip(String(tp))
        if code == 0 && !isempty(tp) && tp != "0"
            return (true, "TracerPid=$tp")
        end
        sleep(0.2)
    end
    _, tp = DistSSHBase._remote_shell_status(
        String(host),
        "awk '/^TracerPid:/ {print \$2}' $status_path 2>/dev/null",
    )
    return (false, "timeout=$(timeout)s TracerPid=$(repr(strip(String(tp))))")
end

function _hb_strace_report!(host::AbstractString, worker_pid::Int, t_stop::Float64)
    trace = _remote_cat(host, _trace_path(worker_pid))
    hb_lines = String[]
    exit_lines = String[]
    last_lines = String[]
    for line in split(trace, '\n')
        push!(last_lines, line)
        length(last_lines) > 80 && popfirst!(last_lines)
        occursin(_HB_EXIT75_NEEDLE, line) && push!(hb_lines, line)
        occursin("DistSSHHeartbeat", line) && push!(hb_lines, line)
        occursin("exit_group", line) && push!(exit_lines, line)
        occursin("exited with", line) && push!(exit_lines, line)
    end
    _hb_diag_log("strace vs STOP: worker_pid=$worker_pid STOP_unix=$(round(t_stop; digits = 3))")
    _hb_diag_log("strace heartbeat/write lines ($(length(hb_lines))):")
    for ln in hb_lines
        _hb_diag_log("  $(ln)")
    end
    _hb_diag_log("strace exit_group/exited lines ($(length(exit_lines))):")
    for ln in exit_lines
        _hb_diag_log("  $(ln)")
    end
    if isempty(exit_lines) && !isempty(trace)
        _hb_diag_log("strace last ~$(length(last_lines)) lines:")
        for ln in last_lines
            isempty(strip(ln)) || _hb_diag_log("  $(ln)")
        end
    end
    return nothing
end

function _hb_strace_stop!(host::AbstractString, worker_pid::Int)
    tp_pid = DistSSHBase._remote_shell_path_word(_trace_path(worker_pid) * ".strace_pid")
    tp = DistSSHBase._remote_shell_path_word(_trace_path(worker_pid))
    DistSSHBase._remote_shell_status(
        String(host),
        "test -f $tp_pid && sudo -n kill \$(cat $tp_pid) 2>/dev/null || true; rm -f $tp $tp_pid",
    )
    return nothing
end

function _dump_stop_failure_diagnostics!(
        host::AbstractString,
        worker_os_pid::Int,
        exit_path::Union{Nothing, AbstractString},
        t_stop::Float64,
        master_pid::Int,
        monitor_diag::AbstractString,
    )
    _hb_diag_log("STOP was at unix=$(round(t_stop; digits = 3)) master_pid=$master_pid")
    _hb_diag_log("monitor check before STOP (from master): $(strip(monitor_diag))")
    _log_pgrep_snapshot!(host, "at-failure")
    _hb_strace_report!(host, worker_os_pid, t_stop)
    if exit_path !== nothing
        _hb_diag_log("exit wrapper ls:\n$(_remote_ls(host, exit_path))")
        _hb_diag_log("exit wrapper file: $(repr(strip(_remote_cat(host, exit_path))))")
    end
    return nothing
end

function _master_script_contents(
        ready_path::AbstractString,
        monitor_path::AbstractString,
        wrap_remote::AbstractString,
        ssh_opts::AbstractString,
    )::String
    ready = repr(String(ready_path))
    mon_path = repr(String(monitor_path))
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
    const _monitor_path = $mon_path
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
            monitor = remotecall_fetch(w) do
                sym = :DistSSHHeartbeat
                isdefined(Main, sym) || return "missing_module"
                hb = getfield(Main, sym)
                stop_flag = isdefined(hb, :HEARTBEAT_STOP) ? hb.HEARTBEAT_STOP[][] : "no_HEARTBEAT_STOP"
                ver = isdefined(hb, :HEARTBEAT_CODE_VERSION) ? hb.HEARTBEAT_CODE_VERSION : "?"
                return "worker=\$(myid()) stop=\$(stop_flag) ver=\$(ver)"
            end
            open(_monitor_path, "w") do io
                println(io, monitor)
                println(io, "interval=\$_interval deadline=\$_deadline")
                println(io, "worker_os_pid=\$worker_os_pid")
            end
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
            master_script = ready_path = monitor_path = nothing
            master_pid = Ref(0)
            worker_os_pid = Ref(0)
            monitor_diag = ""
            try
                wrap_path, exit_path = _install_worker_wrapper!(_host, tag, remote_julia)
                run_dir = mktempdir()
                ready_path = joinpath(run_dir, "ready.txt")
                monitor_path = joinpath(run_dir, "monitor.txt")
                master_script = joinpath(run_dir, "master.jl")
                ssh_opts = "-F $(_ssh_config) -o RequestTTY=no"
                write(master_script, _master_script_contents(ready_path, monitor_path, wrap_path, ssh_opts))
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
                        if length(lines) >= 3 && lines[1] != "error"
                            master_pid[] = parse(Int, lines[1])
                            worker_id[] = parse(Int, lines[2])
                            worker_os_pid[] = parse(Int, lines[3])
                            break
                        elseif lines[1] == "error"
                            _fail("master failed before ready: $(join(lines[2:end], '\n'))")
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

                if isfile(monitor_path)
                    monitor_diag = read(monitor_path, String)
                    _hb_diag_log("monitor pre-STOP: $(strip(monitor_diag))")
                else
                    _hb_diag_log("monitor pre-STOP: missing file $monitor_path")
                end

                _log_pgrep_snapshot!(_host, "before-STOP")
                _hb_diag_log(
                    "tracking worker_os_pid=$(worker_os_pid[]) (Distributed worker=$(worker_id[]))",
                )

                trace_started, trace_start_detail = _hb_strace_begin!(_host, worker_os_pid[])
                _hb_diag_log("strace begin ok=$trace_started detail=$(repr(trace_start_detail))")
                trace_attached, attach_detail =
                    _hb_strace_wait_attached!(_host, worker_os_pid[]; timeout = 30)
                _hb_diag_log("strace attach ok=$trace_attached detail=$(repr(attach_detail))")
                pids_before = _worker_julia_pids(_host)
                isempty(pids_before) && _fail("no worker julia pids on $_host before STOP")
                worker_os_pid[] in pids_before ||
                    _fail(
                    "tracked worker_os_pid=$(worker_os_pid[]) not in pgrep before STOP: $pids_before",
                )

                sleep(_INTERVAL_SEC + 0.5)
                run(`kill -STOP $(master_pid[])`)
                t_stop = time()
                _hb_diag_log("STOP master_pid=$(master_pid[]) at unix=$(round(t_stop; digits = 3))")

                sleep(max(0.0, _DEADLINE_SEC - 1.0))
                live_at_check = _worker_julia_pids(_host)
                _hb_diag_log("alive-check pgrep pids=$live_at_check")
                @test !isempty(live_at_check)

                gone = false
                t1 = time()
                while (time() - t1) < _GONE_TIMEOUT_SEC
                    if isempty(_worker_julia_pids(_host))
                        gone = true
                        break
                    end
                    sleep(0.25)
                end
                if !gone
                    _dump_stop_failure_diagnostics!(
                        _host,
                        worker_os_pid[],
                        exit_path,
                        t_stop,
                        master_pid[],
                        monitor_diag,
                    )
                    _fail(
                        "worker still alive after STOP + $(round(time() - t_stop; digits = 1))s " *
                            "(timeout=$(_GONE_TIMEOUT_SEC)s) pids=$(_worker_julia_pids(_host))",
                    )
                end
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
                if worker_os_pid[] > 0
                    try
                        _hb_strace_stop!(_host, worker_os_pid[])
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
