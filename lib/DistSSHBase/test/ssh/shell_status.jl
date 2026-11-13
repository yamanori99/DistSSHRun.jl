using Test

"""Run `argv` to completion. `signal` kills it once `run` has returned the process."""
function _shell_status_proc(argv::Vector{String}; signal::Union{Nothing, Integer} = nothing)
    proc = run(ignorestatus(Cmd(argv)); wait = false)
    if signal === nothing
        wait(proc)
        return proc
    end
    process_running(proc) || error("$(argv[1]) exited before signal $(signal)")
    kill(proc, signal)
    wait(proc)
    process_exited(proc) || error("$(argv[1]) still running after signal $(signal)")
    return proc
end

@testset "shell_status" begin
    @test Base.ispublic(DistSSHBase, :shell_status)
    @test !Base.isexported(DistSSHBase, :shell_status)

    @testset "signals" begin
        term = _shell_status_proc(["sleep", "30"]; signal = Base.SIGTERM)
        killp = _shell_status_proc(["sleep", "30"]; signal = Base.SIGKILL)
        int = _shell_status_proc(["sleep", "30"]; signal = Base.SIGINT)
        pipe = _shell_status_proc(["sleep", "30"]; signal = Base.SIGPIPE)
        @test DistSSHBase.shell_status(term) == 143
        @test DistSSHBase.shell_status(killp) == 137
        @test DistSSHBase.shell_status(int) == 130
        @test DistSSHBase.shell_status(pipe) == 141
        @test term.exitcode == 0 && term.termsignal == 15
        @test killp.termsignal == 9
        @test int.termsignal == 2
        @test pipe.termsignal == 13
    end

    @testset "plain exits" begin
        for code in (0, 3, 127, 255)
            proc = _shell_status_proc(["sh", "-c", "exit $code"])
            @test proc.termsignal == 0
            @test DistSSHBase.shell_status(proc) == code
        end
    end

    @testset "not exited" begin
        proc = run(ignorestatus(`sleep 30`); wait = false)
        try
            @test_throws ArgumentError("shell_status: process has not exited") DistSSHBase.shell_status(proc)
            @test process_running(proc)
        finally
            process_running(proc) && kill(proc, Base.SIGKILL)
            wait(proc)
        end
    end
end
