using Test

@testset "juliaup where" begin
    @test DistSSHBase.remote_juliaup_candidates("Darwin") == [
        raw"$HOME/.juliaup/bin/juliaup",
        "/opt/homebrew/bin/juliaup",
        "/usr/local/bin/juliaup",
    ]
    @test DistSSHBase.remote_juliaup_candidates("Linux") == [raw"$HOME/.juliaup/bin/juliaup"]
    @test DistSSHBase._juliaup_candidate_sh_word(raw"$HOME/.juliaup/bin/juliaup") ==
        "\"\$HOME/.juliaup/bin/juliaup\""
    @test occursin(".juliaup", DistSSHBase.local_juliaup_candidates()[1])
    @test DistSSHBase.find_local_juliaup(String[]) === nothing
    _with_tempdir() do tmp
        ju = joinpath(tmp, "juliaup")
        @test DistSSHBase._local_julia_beside_juliaup(ju) == joinpath(tmp, "julia")
    end
end
