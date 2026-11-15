using Test

@testset "tool_require" begin
    sha_id = Base.PkgId(Base.UUID("ea8e919c-243c-51af-8825-aaa63cd721ce"), "SHA")
    mod1 = DistSSHBase.tool_require(sha_id)
    mod2 = DistSSHBase.tool_require(sha_id)
    @test mod1 === mod2
    @test mod1 === Base.loaded_modules[sha_id]

    wrong_sha = Base.PkgId(Base.UUID("01234567-0123-0123-0123-012345678901"), "SHA")
    err = try
        DistSSHBase.tool_require(wrong_sha)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("tool_require: package name collision for SHA", sprint(showerror, err))
    @test mod1 === Base.loaded_modules[sha_id]

    bogus = Base.PkgId(Base.UUID("01234567-0123-0123-0123-012345678901"), "DistSSHNoSuchPkg")
    load_err = try
        DistSSHBase.tool_require(bogus)
        nothing
    catch e
        e
    end
    @test load_err !== nothing
    @test !haskey(Base.loaded_modules, bogus)
end