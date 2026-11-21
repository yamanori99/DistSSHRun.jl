using Test
using DistSSHBase

const _PROCS_ENV_KEY = "DISTSSH_BASE_PROCS_TEST"

@testset "procs" verbose = true begin
    Sys.isunix() || @test_skip "process listing tests require Unix"

    @testset "processes_with_env detach julia" begin
        tag = "base-procs-$(getpid())-$(rand(UInt32))"
        julia = joinpath(Sys.BINDIR, Base.julia_exename())
        cmd = `$julia --startup-file=no -e 'sleep(600)'`
        proc = setenv(cmd, _PROCS_ENV_KEY => tag)
        proc = detach(proc)
        run(proc; wait = false)
        try
            sleep(0.5)
            rows = processes_with_env(_PROCS_ENV_KEY, tag)
            @test !isempty(rows)
            pids = Set(row.pid for row in rows)
            @test getpid() ∉ pids
            other = "base-procs-other-$(rand(UInt32))"
            narrow = processes_with_env(_PROCS_ENV_KEY, tag[1:min(end, 12)]; prefix = true)
            wide = processes_with_env(_PROCS_ENV_KEY, other)
            @test !isempty(narrow)
            @test isempty(wide)
            reap!(rows)
            gone = wait_gone(() -> processes_with_env(_PROCS_ENV_KEY, tag); timeout = 5.0)
            @test isempty(gone)
        finally
            rows = processes_with_env(_PROCS_ENV_KEY, tag)
            reap!(rows)
        end
    end
end
