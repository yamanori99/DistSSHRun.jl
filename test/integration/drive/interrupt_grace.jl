using Test

# Detached `drive` plus `terminate!`. Child Julia, so this is integration.

@testset "terminate! interrupt_grace" begin
    function wait_file(path, seconds)
        t0 = time()
        while !isfile(path) && (time() - t0) < seconds
            sleep(0.05)
        end
        return isfile(path)
    end
    function catch_script(ready, mark)
        return """
        # macOS keeps SIGINT pending across a blocking wait. Julia 1.13
        # observes it at `GC.safepoint` (`InterruptException`). Julia 1.14
        # throws `CancellationRequest` from `sleep`, and a safepoint does not.
        function _interrupt_seen(e)
            DistSSHRun.DistSSHBase.is_sigint(e) && return true
            e isa CapturedException && return _interrupt_seen(e.ex)
            e isa RemoteException && return _interrupt_seen(e.captured.ex)
            e isa TaskFailedException && return _interrupt_seen(e.task.exception)
            return false
        end
        function main()
            # Write `ready` inside the `try`. Julia 1.13 delivers SIGINT at
            # the next safepoint, so a file written before `try` lets
            # `terminate!` land in that gap and this `catch` never runs.
            try
                write($(repr(ready)), "1")
                t0 = time()
                while time() - t0 < 120
                    GC.safepoint()
                    isdefined(Base, :CancellationRequest) && sleep(0.05)
                end
            catch e
                if _interrupt_seen(e)
                    write($(repr(mark)), "1")
                else
                    rethrow()
                end
            end
            return nothing
        end
        """
    end
    _with_tempdir() do proj
        _write_host_project!(proj, "TerminateInt")
        script = joinpath(proj, "job.jl")
        ready = joinpath(proj, "ready")
        mark = joinpath(proj, "caught")
        write(script, catch_script(ready, mark))
        kp = DistSSHRun.execute!(
            :drive,
            script,
            ["parent:1"];
            detached = true,
            project = proj,
            quiet = true,
        )
        try
            @test wait_file(ready, 90)
            DistSSHRun.terminate!(kp; interrupt_grace = 5, grace = 2)
            @test isfile(mark)
        finally
            process_running(kp.process) && DistSSHRun.terminate!(kp; grace = 1)
        end
        rm(ready; force = true)
        rm(mark; force = true)
        kp0 = DistSSHRun.execute!(
            :drive,
            script,
            ["parent:1"];
            detached = true,
            project = proj,
            quiet = true,
        )
        try
            @test wait_file(ready, 90)
            DistSSHRun.terminate!(kp0; interrupt_grace = 0, grace = 2)
            @test !isfile(mark)
        finally
            process_running(kp0.process) && DistSSHRun.terminate!(kp0; grace = 1)
        end
    end
end

@testset "terminate! interrupt_grace reaches a drive worker" begin
    # While the driver waits in `pmap`, Julia 1.13 exits 0 and the worker
    # `catch` does not run. Measured on macOS, Ubuntu, and WSL. Julia 1.14
    # on macOS exits 130, and the worker `catch` still does not run.
    _with_tempdir() do proj
        _write_host_project!(proj, "TerminateWorker")
        script = joinpath(proj, "job.jl")
        ready = joinpath(proj, "ready")
        caught = joinpath(proj, "worker_caught")
        write(
            script,
            """
            using Distributed
            function main()
                pmap(1:nworkers()) do _
                    write($(repr(ready)), "1")
                    try
                        t0 = time()
                        while time() - t0 < 120
                            GC.safepoint()
                            sleep(0.05)
                        end
                    catch e
                        write($(repr(caught)), "1")
                        rethrow()
                    end
                    return nothing
                end
                return nothing
            end
            """,
        )
        kp = DistSSHRun.execute!(
            :drive,
            script,
            ["parent:1"];
            detached = true,
            project = proj,
            quiet = true,
        )
        try
            t0 = time()
            while !isfile(ready) && (time() - t0) < 90
                sleep(0.05)
            end
            @test isfile(ready)
            r = DistSSHRun.terminate!(kp; interrupt_grace = 15, grace = 2)
            @test_broken isfile(caught)
            if isdefined(Base, :CancellationRequest)
                @test r.exit_code == 130
            else
                @test_broken r.exit_code == 130
            end
        finally
            process_running(kp.process) && DistSSHRun.terminate!(kp; grace = 1)
        end
    end
end
