using Test
using Distributed
using DistSSHHeartbeat

function _wait_flag(flag::Ref{Bool}; timeout::Float64 = 2.0)
    t0 = time()
    while !flag[] && (time() - t0) < timeout
        sleep(0.02)
    end
    return flag[]
end

@testset "DistSSHHeartbeat" verbose = true begin
    @testset "WORKER_SOURCE parses and evals into a throwaway module" begin
        src = DistSSHHeartbeat.WORKER_SOURCE
        @test Meta.parseall(src) isa Expr
        m = Module()
        Core.eval(m, Meta.parseall(src))
        @test isdefined(m, :DistSSHHeartbeat)
        hb = m.DistSSHHeartbeat
        @test hb.HEARTBEAT_CODE_VERSION == DistSSHHeartbeat.HEARTBEAT_CODE_VERSION
        @test isdefined(hb, :ping_master)
        @test isdefined(hb, :start_heartbeat_monitor)
        @test isdefined(hb, :stop_heartbeat_monitor)
    end

    @testset "_heartbeat_config" begin
        cfg = DistSSHHeartbeat._heartbeat_config(Dict{String, String}())
        @test cfg.interval == 30.0
        @test cfg.deadline == 600.0
        cfg = DistSSHHeartbeat._heartbeat_config(
            Dict(
                "DISTRIBUTED_HEARTBEAT_INTERVAL_SEC" => "2",
                "DISTRIBUTED_HEARTBEAT_DEADLINE_SEC" => "9",
            )
        )
        @test cfg.interval == 2.0
        @test cfg.deadline == 9.0
        cfg = DistSSHHeartbeat._heartbeat_config(
            Dict(
                "DISTRIBUTED_HEARTBEAT_INTERVAL_SEC" => "nope",
                "DISTRIBUTED_HEARTBEAT_DEADLINE_SEC" => "-1",
            )
        )
        @test cfg.interval == 30.0
        @test cfg.deadline == 600.0
        withenv("DISTSSHKIT_WAIT_PEER_SILENT" => "42") do
            bare = DistSSHHeartbeat._heartbeat_config(Dict{String, String}())
            @test bare.deadline == 42.0
        end
        withenv("DISTSSHKIT_WAIT_PEER_SILENT" => "0") do
            bare = DistSSHHeartbeat._heartbeat_config(Dict{String, String}())
            @test bare.deadline == 600.0
        end
    end

    @testset "_master_alive" begin
        @test DistSSHHeartbeat._master_alive(0.0, 10.0, 10.0)
        @test DistSSHHeartbeat._master_alive(0.0, 10.0, 9.9)
        @test !DistSSHHeartbeat._master_alive(0.0, 10.0, 10.1)
    end

    @testset "_run_heartbeat! silent stall trips on_dead" begin
        stop = Ref(false)
        dead = Ref(false)
        ch = Channel{Nothing}(0)
        hb = DistSSHHeartbeat._run_heartbeat!(
            stop, 0.05, 0.12;
            ping = () -> take!(ch),
            on_dead = () -> (dead[] = true),
        )
        try
            @test _wait_flag(dead; timeout = 5.0)
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
        DistSSHHeartbeat._run_heartbeat!(
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
        DistSSHHeartbeat._run_heartbeat!(
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
        hb = DistSSHHeartbeat._run_heartbeat!(
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

    @testset "ping: module closure fails; myid works" begin
        addprocs(1)
        w = workers()[end]
        try
            DistSSHHeartbeat._remote_include_nothing(w, DistSSHHeartbeat.WORKER_SOURCE)
            @test remotecall_fetch(w, :DistSSHHeartbeat) do sym
                hb = getfield(Main, sym)
                Base.invokelatest(hb.ping_master)
            end
            @test_throws RemoteException remotecall_fetch(w, :DistSSHHeartbeat) do sym
                hb = getfield(Main, sym)
                Core.eval(hb, :(remotecall_fetch(() -> true, 1)))
            end
        finally
            w in workers() && rmprocs(w; waitfor = 2.0)
        end
    end

    @testset "liveness 1s/5s" begin
        addprocs(1)
        w = workers()[end]
        try
            DistSSHHeartbeat.install_and_start_heartbeat!(
                [w];
                interval = 1.0,
                deadline = 5.0,
            )
            sleep(16.0)
            @test w in workers()
            @test remotecall_fetch(myid, w) == w
        finally
            DistSSHHeartbeat.stop_heartbeat_on_workers!([w])
            w in workers() && rmprocs(w; waitfor = 2.0)
        end
    end

    @testset "stall does not false-positive while master is healthy" begin
        addprocs(1)
        w = workers()[end]
        try
            DistSSHHeartbeat.install_and_start_heartbeat!(
                [w];
                interval = 1.0,
                deadline = 5.0,
            )
            sleep(2.0)
            remotecall_fetch(w) do
                t_end = time() + 8.0
                while time() < t_end
                end
                return nothing
            end
            sleep(3.0)
            @test w in workers()
            @test remotecall_fetch(myid, w) == w
        finally
            DistSSHHeartbeat.stop_heartbeat_on_workers!([w])
            w in workers() && rmprocs(w; waitfor = 2.0)
        end
    end

    @testset "without DistSSHRun in the worker project" begin
        addprocs(1)
        w = workers()[end]
        try
            DistSSHHeartbeat.install_and_start_heartbeat!(
                [w];
                interval = 1.0,
                deadline = 5.0,
            )
            @test remotecall_fetch(w, :DistSSHHeartbeat) do sym
                hb = isdefined(Main, sym) ? getfield(Main, sym) : nothing
                !isdefined(Main, :DistSSHRun) &&
                    hb !== nothing &&
                    Base.invokelatest(hb.ping_master)
            end
        finally
            DistSSHHeartbeat.stop_heartbeat_on_workers!([w])
            w in workers() && rmprocs(w; waitfor = 2.0)
        end
    end

    @testset "older DistSSHRun on LOAD_PATH is not used" begin
        fake = mktempdir()
        try
            mkpath(joinpath(fake, "DistSSHRun", "src"))
            write(
                joinpath(fake, "DistSSHRun", "Project.toml"),
                """
                name = "DistSSHRun"
                uuid = "b568025c-2759-4ef1-8b14-17d00e2cd000"
                version = "0.1.0"
                """,
            )
            write(
                joinpath(fake, "DistSSHRun", "src", "DistSSHRun.jl"),
                "module DistSSHRun\nconst FROM = :user_manifest\nend\n",
            )
            addprocs(1)
            w = workers()[end]
            try
                remotecall_fetch(w, joinpath(fake, "DistSSHRun")) do p
                    pushfirst!(LOAD_PATH, p)
                    return nothing
                end
                DistSSHHeartbeat.install_and_start_heartbeat!(
                    [w];
                    interval = 1.0,
                    deadline = 5.0,
                )
                ver = DistSSHHeartbeat.HEARTBEAT_CODE_VERSION
                @test remotecall_fetch(w, :DistSSHHeartbeat, ver) do sym, v
                    hb = getfield(Main, sym)
                    Base.invokelatest(hb.ping_master) && hb.HEARTBEAT_CODE_VERSION == v
                end
            finally
                DistSSHHeartbeat.stop_heartbeat_on_workers!([w])
                w in workers() && rmprocs(w; waitfor = 2.0)
            end
        finally
            rm(fake; force = true, recursive = true)
        end
    end

    @testset "SSH E2E" begin
        if get(ENV, "DISTSSHKIT_SSH_E2E", "") == "1"
            include(joinpath(@__DIR__, "e2e.jl"))
        else
            @info "DistSSHHeartbeat SSH E2E skipped (set DISTSSHKIT_SSH_E2E=1)"
        end
    end
end
