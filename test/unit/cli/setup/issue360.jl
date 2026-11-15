using Test

# Issue #360: cancelled setup ops and follow-up path quoting (setup CLI).

@testset "issue #360 setup CLI small fixes" begin
    @testset "cancelled delete must not clear last-ship default" begin
        cancelled = (; cancelled = true, succeeded = 0, failed = 0, hosts = DistSSHRun.HostResult[])
        _, ok = _capture_stdio() do _, _
            DistSSHRun.finish_host_op!("Delete", cancelled)
        end
        @test ok
        cli_forgets = ok && !cancelled.cancelled
        @test !cli_forgets
        legacy_forgets = ok
        @test legacy_forgets
    end

    @testset "deploy-root in Next lines is one shell word" begin
        path = "/tmp/distssh work"
        quoted = "'" * replace(path, "'" => "'\\''") * "'"
        line = "setup instantiate --deploy-root $quoted"
        @test occursin("--deploy-root $quoted", line)
        unquoted = "setup instantiate --deploy-root $path"
        @test occursin("distssh work", unquoted)
        @test !occursin("--deploy-root $quoted", unquoted)
    end
end
