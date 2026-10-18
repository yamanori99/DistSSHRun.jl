using Test

# Oracle: SIGINT while `main` runs prints the cleanup line and exits 130.
# Julia 1.14 only. On 1.13 the signal can land in a Distributed task instead.

@testset "drive SIGINT" begin
    if !isdefined(Base, :CancellationRequest)
        @test true
    else
        _mktemp_host() do proj
            _write_host_project!(proj, "SigintApp")
            script = joinpath(proj, "job.jl")
            cp(_fixture("drive_sigint.jl"), script; force = true)
            marker = joinpath(proj, "main_started")
            cmd = _kit_drive_cmd(;
                script, host_root = proj, parent_workers = 2,
                extra_env = Dict("DISTSSHKIT_TEST_SIGINT_MARKER" => marker),
            )
            proc, reader = _start_subprocess(cmd)
            started = timedwait(() -> isfile(marker) || !process_running(proc), 300.0; pollint = 0.5)
            @test started === :ok && isfile(marker)
            sleep(2)
            kill(proc, Base.SIGINT)
            stopped = timedwait(() -> !process_running(proc), 60.0; pollint = 0.5)
            stopped === :ok || kill(proc, Base.SIGKILL)
            wait(proc)
            combined = fetch(reader)
            if proc.exitcode != 130
                println(stderr, "──── drive SIGINT (exit=$(proc.exitcode)) ────")
                println(stderr, combined)
                println(stderr, "──── end drive SIGINT output ────")
            end
            @test stopped === :ok
            @test proc.exitcode == 130
            @test occursin("Interrupted. Cleaning up workers...", combined)
        end
    end
end
