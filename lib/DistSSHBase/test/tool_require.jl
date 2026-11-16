using Test

@testset "tool_require" begin
    bad = Base.PkgId(Base.UUID("b568025c-2759-4ef1-8b14-17d00e2cd000"), "DistSSHRun")
    @test_throws ErrorException DistSSHBase.tool_require(bad)
end
