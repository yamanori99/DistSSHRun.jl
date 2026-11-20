using Test

@testset "SSH preflight gate honors best_effort" begin
    root = abspath(joinpath(@__DIR__, "..", "..", "..", "..", ".."))
    run_src = read(joinpath(root, "src", "DistSSHRun", "core", "drive", "run.jl"), String)
    @test occursin("!preflight_setup_ssh(ssh_preflight_hosts) && !best_effort", run_src)
end
