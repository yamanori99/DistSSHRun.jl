using Test

@testset "CliCursor" begin
    @testset "positional args" begin
        c = DistSSHBase.CliCursor(["host1", "host2"])
        @test DistSSHBase.cli_current(c) == "host1"
        DistSSHBase.cli_consume!(c)
        @test DistSSHBase.cli_current(c) == "host2"
        DistSSHBase.cli_consume!(c)
        @test DistSSHBase.cli_at_end(c)
    end

    @testset "cli_take_value!" begin
        c = DistSSHBase.CliCursor(["--julia", "/opt/julia/bin/julia"])
        @test DistSSHBase.cli_current(c) == "--julia"
        @test DistSSHBase.cli_take_value!(c, "--julia") == "/opt/julia/bin/julia"
        @test DistSSHBase.cli_at_end(c)
    end

    @testset "missing value" begin
        c = DistSSHBase.CliCursor(["--julia"])
        @test_throws ArgumentError DistSSHBase.cli_take_value!(c, "--julia")
    end
end
