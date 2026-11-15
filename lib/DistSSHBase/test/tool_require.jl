using Test
using DistSSHBase: tool_require

@testset "tool_require" begin
    sha_id = Base.PkgId(Base.UUID("ea8e919c-243c-51af-8825-aaa63cd721ce"), "SHA")
    mod1 = tool_require(sha_id)
    mod2 = tool_require(sha_id)
    @test mod1 === mod2
    @test mod1 === Base.loaded_modules[sha_id]
end