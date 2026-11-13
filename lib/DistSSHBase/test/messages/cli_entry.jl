using Test

@testset "cli entry" begin
    @test DistSSHBase.cli_entry() === :DistSSHKit
    @test DistSSHBase.cli_m() == "julia -m DistSSHKit"
    @test DistSSHBase.cli_m_project() == "julia --project=. -m DistSSHKit"
    @test DistSSHBase.cli_qhost() == "qhost "
    seen = Symbol[]
    DistSSHBase.with_cli_entry(:DistSSHRun) do
        push!(seen, DistSSHBase.cli_entry())
        DistSSHBase.with_cli_entry(:DistSSHQueue) do
            push!(seen, DistSSHBase.cli_entry())
        end
        push!(seen, DistSSHBase.cli_entry())
        @test DistSSHBase.cli_m() == "julia -m DistSSHRun"
        @test DistSSHBase.cli_qhost() == ""
        @test DistSSHBase.cli_heading("up") == "DistSSHRun up"
        @test DistSSHBase.cli_qhost_heading("setup") == "DistSSHRun setup"
    end
    @test seen == [:DistSSHRun, :DistSSHRun, :DistSSHRun]
    @test DistSSHBase.cli_entry() === :DistSSHKit
    DistSSHBase.with_cli_entry(:DistSSHKit) do
        @test DistSSHBase.cli_qhost_heading("up") == "DistSSHKit qhost up"
    end
    @test DistSSHBase.cli_entry() === :DistSSHKit
end
