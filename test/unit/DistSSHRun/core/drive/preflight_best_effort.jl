using Test

@testset "SSH preflight gate honors best_effort" begin
    root = abspath(joinpath(@__DIR__, "..", "..", "..", "..", ".."))
    run_src = read(joinpath(root, "src", "DistSSHRun", "core", "drive", "run.jl"), String)
    ride_src = read(joinpath(root, "src", "DistSSHRun", "ride.jl"), String)
    @test occursin("!preflight_setup_ssh(ssh_preflight_hosts) && !best_effort", run_src)
    @test occursin("!preflight_setup_ssh(child_hosts) && !best_effort", ride_src)
end
