using Test
using Distributed

# Oracle: worker lifecycle helpers in drive/runtime/workers.jl (DistSSHRun module).
# Do not `include` the runtime sources from this file: JetLS follows top-level
# `include()` from `test/runtests.jl` and would type-check production
# `workers.jl` inside a test module.

const _EMPTY_DRIVE_HOSTS = Tuple{String, Union{Int, Nothing}}[]

@testset "drive workers lifecycle" begin
    _with_tempdir() do tmp

        @testset "setup_cli_host_token child token" begin
            host_name = "worker-host"
            hint = "hint: julia --project=. -m DistSSHKit setup --instantiate $(DistSSHRun.setup_cli_host_token(host_name))"
            @test occursin("child:worker-host", hint)
        end

        @testset "register_worker_cleanup! lone master is a no-op" begin
            @test nprocs() == 1
            @test workers() == [1]
            cleanup = DistSSHRun.register_worker_cleanup!(String[])
            # Must not rmprocs([1]) / warn "process 1 not removed".
            @test cleanup() === nothing
            @test nprocs() == 1
            @test workers() == [1]
            @test cleanup() === nothing
        end

        @testset "_interrupt_drive_workers! (#371)" begin
            @test nprocs() == 1
            @test DistSSHRun._interrupt_drive_workers!() === nothing
            addprocs(1; topology = :master_worker)
            added = workers()
            seen = Int[]
            prev = DistSSHRun.INTERRUPT_DRIVE_WORKERS[]
            DistSSHRun.INTERRUPT_DRIVE_WORKERS[] = pids -> append!(seen, pids)
            try
                @test DistSSHRun._interrupt_drive_workers!() === nothing
                @test seen == added
                @test workers() == added
            finally
                DistSSHRun.INTERRUPT_DRIVE_WORKERS[] = prev
                for w in added
                    w in workers() && rmprocs(w; waitfor = 2.0)
                end
            end
            @test nprocs() == 1
        end

        @testset "_group_interrupt_targets" begin
            rows = [
                (1, :local),
                (2, :local),
                (3, ("dev@child-1", 40)),
                (4, ("dev@child-1", 41)),
                (5, ("child-2", 7)),
                (6, nothing),
            ]
            g = DistSSHRun._group_interrupt_targets(rows)
            @test g.local_pids == [1, 2]
            @test g.fallback == [6]
            @test g.ssh["dev@child-1"] == [40, 41]
            @test g.ssh["child-2"] == [7]
            @test DistSSHRun._group_interrupt_targets(Tuple{Int, Any}[]).local_pids == Int[]
        end

        @testset "WorkerConfig.ospid is the julia pid" begin
            addprocs(1; topology = :master_worker)
            added = workers()
            try
                wpid = added[end]
                wrk = Distributed.map_pid_wrkr[wpid]
                @test wrk isa Distributed.Worker
                if wrk isa Distributed.Worker
                    # Same field `kill -INT` reads. `JoinCompleteMsg` sends `getpid()`.
                    @test wrk.config.ospid == remotecall_fetch(getpid, wpid)
                    @test wrk.config.ospid != getpid()
                end
            finally
                for w in added
                    w in workers() && rmprocs(w; waitfor = 2.0)
                end
            end
        end

        @testset "_interrupt_kill_shell names those pids" begin
            @test DistSSHRun._interrupt_kill_shell([4242, 4243]) == "kill -INT 4242 4243 || true"
            @test !occursin("pkill", DistSSHRun._interrupt_kill_shell([7]))
        end

        @testset "kill -INT ssh options and deadline" begin
            @test DistSSHRun._INTERRUPT_SSH_PHASE_S ==
                Float64(DistSSHRun.DistSSHBase._SSH_CONNECT_TIMEOUT_S)
            @test DistSSHRun._SSH_PHASE_CONCURRENCY == 8
            withenv("DISTRIBUTED_SSH_OPTS" => nothing) do
                cmd = DistSSHRun._ssh_phase_cmd("child.example", "kill -INT 4242 || true")
                argv = collect(cmd)
                i5 = findfirst(==("ServerAliveInterval=5"), argv)
                i60 = findfirst(==("ServerAliveInterval=60"), argv)
                @test i5 !== nothing && i60 !== nothing && i5 < i60
                @test "ServerAliveCountMax=1" in argv
                @test "BatchMode=yes" in argv
                @test "ConnectTimeout=$(DistSSHRun.DistSSHBase._SSH_CONNECT_TIMEOUT_S)" in argv
                @test any(arg -> occursin("kill -INT 4242", arg), argv)
            end
            cmds = Cmd[`sleep 30`, `sleep 30`, `sleep 30`]
            runs = DistSSHRun._CmdRun[]
            t0 = time()
            try
                runs = DistSSHRun._run_cmds_bounded!(cmds, 0.4)
                @test time() - t0 < 8
                for run in runs
                    proc = run.proc
                    @test proc isa Base.Process
                    if proc isa Base.Process
                        @test !process_running(proc)
                    end
                end
            finally
                for run in runs
                    proc = run.proc
                    if proc isa Base.Process && process_running(proc)
                        kill(proc, Base.SIGKILL)
                    end
                end
            end
            # A concurrency cap of 1 must not run the queued sleeps after the deadline.
            queued = DistSSHRun._CmdRun[]
            t1 = time()
            try
                queued = DistSSHRun._run_cmds_bounded!(cmds, 0.4; ntasks = 1)
                @test time() - t1 < 8
                for run in queued
                    proc = run.proc
                    if proc isa Base.Process
                        @test !process_running(proc)
                    end
                end
            finally
                for run in queued
                    proc = run.proc
                    if proc isa Base.Process && process_running(proc)
                        kill(proc, Base.SIGKILL)
                    end
                end
            end
        end

        @testset "_interrupt_endpoint local worker" begin
            addprocs(1; topology = :master_worker)
            added = workers()
            try
                @test DistSSHRun._interrupt_endpoint(added[1]) === :local
                @test DistSSHRun._interrupt_endpoint(1) === nothing
            finally
                for w in added
                    w in workers() && rmprocs(w; waitfor = 2.0)
                end
            end
        end

        @testset "register_worker_cleanup! removes added workers" begin
            addprocs(2; topology = :master_worker)
            added = workers()
            @test length(added) == 2
            try
                cleanup = DistSSHRun.register_worker_cleanup!(String[])
                cleanup()
                @test nprocs() == 1
                @test workers() == [1]
                @test cleanup() === nothing
            finally
                for w in added
                    w in workers() && rmprocs(w; waitfor = 2.0)
                end
            end
        end

        @testset "register_worker_cleanup! guard trips before later workers" begin
            addprocs(1; topology = :master_worker)
            pre = workers()[end]
            try
                cleanup = DistSSHRun.register_worker_cleanup!(String[])
                cleanup()
                @test pre ∉ workers()
                addprocs(1; topology = :master_worker)
                other = workers()[end]
                try
                    cleanup()
                    @test other in workers()
                finally
                    other in workers() && rmprocs(other; waitfor = 2.0)
                end
            finally
                pre in workers() && rmprocs(pre; waitfor = 2.0)
            end
        end

        @testset "cleanup_stale_workers! skips localhost with no SSH hosts" begin
            withenv("DISTSSHKIT_SKIP_GLOBAL_WORKER_PKILL" => nothing) do
                mktemp() do path, io
                    redirect_stdout(io) do
                        DistSSHRun.cleanup_stale_workers!(_EMPTY_DRIVE_HOSTS)
                    end
                    flush(io)
                    @test !occursin("Cleaning up stale workers", read(path, String))
                end
            end
        end

        @testset "cleanup_stale_workers! skips untagged remote pkill" begin
            withenv("DISTSSHKIT_SKIP_GLOBAL_WORKER_PKILL" => nothing, "DISTSSHKIT_JOB_ID" => nothing) do
                mktemp() do path, io
                    redirect_stdout(io) do
                        DistSSHRun.cleanup_stale_workers!(
                            Tuple{String, Union{Int, Nothing}}[("example.invalid", 1)],
                        )
                    end
                    flush(io)
                    @test !occursin("Cleaning up stale workers", read(path, String))
                end
            end
        end

        @testset "cleanup_stale_workers! DISTSSHKIT_SKIP_GLOBAL_WORKER_PKILL" begin
            withenv("DISTSSHKIT_SKIP_GLOBAL_WORKER_PKILL" => "1") do
                mktemp() do path, io
                    redirect_stdout(io) do
                        DistSSHRun.cleanup_stale_workers!(
                            Tuple{String, Union{Int, Nothing}}[("example.invalid", 1)],
                        )
                    end
                    flush(io)
                    @test !occursin("Cleaning up stale workers", read(path, String))
                end
            end
        end

        @testset "add_drive_workers! errors when nothing joins" begin
            script = joinpath(tmp, "job.jl")
            write(script, "")
            @test_throws ErrorException redirect_stdout(devnull) do
                DistSSHRun.add_drive_workers!(
                    _EMPTY_DRIVE_HOSTS, 0, nothing, nothing, tmp, script, tmp,
                )
            end
        end

        @testset "add_drive_workers! adds only local workers when requested" begin
            script = joinpath(tmp, "job.jl")
            write(script, "")
            before = Set(workers())
            successful_hosts = redirect_stdout(devnull) do
                DistSSHRun.add_drive_workers!(
                    _EMPTY_DRIVE_HOSTS, 2, nothing, nothing, tmp, script, tmp,
                )
            end
            added = setdiff(Set(workers()), before)
            try
                @test isempty(successful_hosts)
                @test length(added) == 2
                @test nprocs() > 1
                for w in added
                    @test get(DistSSHRun.RUNNER_WORKER_PROJECT_DIRS, w, nothing) == tmp
                end
            finally
                for w in added
                    w in workers() && rmprocs(w; waitfor = 2.0)
                end
            end
        end
    end
end

@testset "drive heartbeat" begin
    @testset "_heartbeat_config" begin
        cfg = DistSSHRun._heartbeat_config(Dict{String, String}())
        @test cfg.interval == 30.0
        @test cfg.deadline == 600.0
        cfg = DistSSHRun._heartbeat_config(
            Dict(
                "DISTRIBUTED_HEARTBEAT_INTERVAL_SEC" => "2",
                "DISTRIBUTED_HEARTBEAT_DEADLINE_SEC" => "9",
            )
        )
        @test cfg.interval == 2.0
        @test cfg.deadline == 9.0
        cfg = DistSSHRun._heartbeat_config(
            Dict(
                "DISTRIBUTED_HEARTBEAT_INTERVAL_SEC" => "nope",
                "DISTRIBUTED_HEARTBEAT_DEADLINE_SEC" => "-1",
            )
        )
        @test cfg.interval == 30.0
        @test cfg.deadline == 600.0
        withenv("DISTSSHKIT_WAIT_PEER_SILENT" => "42") do
            bare = DistSSHRun._heartbeat_config(Dict{String, String}())
            @test bare.deadline == 42.0
            named = DistSSHRun._heartbeat_config(
                Dict("DISTRIBUTED_HEARTBEAT_DEADLINE_SEC" => "9"),
            )
            @test named.deadline == 9.0
        end
        withenv("DISTSSHKIT_WAIT_PEER_SILENT" => "0") do
            bare = DistSSHRun._heartbeat_config(Dict{String, String}())
            @test bare.deadline == 600.0
        end
    end

    @testset "_master_alive" begin
        @test DistSSHRun._master_alive(0.0, 10.0, 10.0)
        @test DistSSHRun._master_alive(0.0, 10.0, 9.9)
        @test !DistSSHRun._master_alive(0.0, 10.0, 10.1)
    end

    function _wait_flag(flag::Ref{Bool}; timeout::Float64 = 2.0)
        t0 = time()
        while !flag[] && (time() - t0) < timeout
            sleep(0.02)
        end
        return flag[]
    end

    @testset "_run_heartbeat! silent stall trips on_dead" begin
        stop = Ref(false)
        dead = Ref(false)
        ch = Channel{Nothing}(0)
        hb = DistSSHRun._run_heartbeat!(
            stop, 0.05, 0.12;
            ping = () -> take!(ch),
            on_dead = () -> (dead[] = true),
        )
        try
            @test _wait_flag(dead)
            @test istaskstarted(hb.prober)
            @test istaskstarted(hb.watchdog)
        finally
            stop[] = true
            close(ch)
        end
    end

    @testset "_run_heartbeat! live ping does not trip" begin
        stop = Ref(false)
        dead = Ref(false)
        DistSSHRun._run_heartbeat!(
            stop, 0.05, 1.0;
            ping = () -> true,
            on_dead = () -> (dead[] = true),
        )
        try
            sleep(1.5)
            @test !dead[]
        finally
            stop[] = true
        end
    end

    @testset "_run_heartbeat! blip then recover" begin
        stop = Ref(false)
        dead = Ref(false)
        n = Ref(0)
        DistSSHRun._run_heartbeat!(
            stop, 0.04, 0.35;
            ping = () -> (n[] += 1; n[] <= 2 && error("blip"); true),
            on_dead = () -> (dead[] = true),
        )
        try
            sleep(0.45)
            @test !dead[]
            @test n[] > 2
        finally
            stop[] = true
        end
    end

    @testset "_run_heartbeat! stop ends both tasks" begin
        stop = Ref(false)
        hb = DistSSHRun._run_heartbeat!(
            stop, 0.03, 10.0;
            ping = () -> true,
            on_dead = () -> error("should not die"),
        )
        stop[] = true
        wait(hb.prober)
        wait(hb.watchdog)
        @test istaskdone(hb.prober)
        @test istaskdone(hb.watchdog)
    end

    @testset "publish defs skip top-level work on workers" begin
        _with_tempdir() do tmp
            p = joinpath(tmp, "plain.jl")
            write(
                p, """
                function work(x)
                    return x * x
                end
                xs = 1:8
                println("SHOULD_NOT_PUBLISH")
                """
            )
            src = DistSSHRun._drive_publish_source(p)
            @test occursin("function work", src)
            @test !occursin("SHOULD_NOT_PUBLISH", src)
            addprocs(1; topology = :master_worker)
            w = workers()[end]
            try
                remotecall_fetch(w, src) do code
                    include_string(Main, code)
                    return nothing
                end
                @test remotecall_fetch(w) do
                    isdefined(Main, :work) && Base.invokelatest(getfield(Main, :work), 3) == 9
                end
            finally
                w in workers() && rmprocs(w; waitfor = 2.0)
            end
        end
    end

    @testset "sync_driver_to_workers! warns and skips guarded include (#380)" begin
        _with_tempdir() do tmp
            lib = joinpath(tmp, "lib.jl")
            write(lib, "other_loaded() = true\n")
            g = joinpath(tmp, "guarded.jl")
            write(
                g, """
                using Distributed
                function work(x)
                    return x * x
                end
                isdefined(Main, :other_loaded) || include(joinpath(@__DIR__, "lib.jl"))
                """
            )
            addprocs(1; topology = :master_worker)
            w = workers()[end]
            try
                DistSSHRun._drive_include_workers(DistSSHRun._DRIVE_WORKER_BOOTSTRAP)
                out, _ = _capture_stdio() do _, _
                    DistSSHRun.sync_driver_to_workers!(g)
                end
                @test occursin("is not published", out)
                @test occursin("--sync-script", out)
                @test remotecall_fetch(w) do
                    isdefined(Main, :work) && Base.invokelatest(getfield(Main, :work), 3) == 9
                end
                # The guarded include never reached the worker.
                @test !remotecall_fetch(w) do
                    isdefined(Main, :other_loaded)
                end
            finally
                w in workers() && rmprocs(w; waitfor = 2.0)
            end
        end
    end
end
