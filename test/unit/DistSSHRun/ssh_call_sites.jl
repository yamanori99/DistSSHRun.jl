using Test

@testset "ssh-call-sites-check.jl" begin
    repo = abspath(joinpath(@__DIR__, "..", "..", ".."))
    proc = run(
        pipeline(
            `julia --startup-file=no --project=$repo $(joinpath(repo, ".github", "ssh-call-sites-check.jl"))`;
            stdout = IOBuffer(),
            stderr = IOBuffer(),
        );
        wait = true,
    )
    @test proc.exitcode == 0
end