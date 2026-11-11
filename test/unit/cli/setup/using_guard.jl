using Test

# Regression: `go` may already have bound DistSSHRun names (including
# `cli_project_root`) before `setup.jl` is included. The setup `_using` guard
# must not key off `cli_project_root`, or `resolve_remote_project_root` never lands.

@testset "setup _using after cli_project_root" begin
    mod_name = Symbol(:SetupUsingAfterCli, "_", rand(UInt))
    Core.eval(Main, Meta.parse("module $mod_name end"))
    m = getfield(Main, mod_name)
    Core.eval(m, :(const DistSSHRun = $(DistSSHRun)))
    Core.eval(
        m, quote
            using .DistSSHRun: cli_project_root
            const _cli_bound_before_setup = cli_project_root
        end
    )
    kit_src = abspath(joinpath(@__DIR__, "..", "..", "..", "..", "src"))
    setup_jl = joinpath(kit_src, "cli", "setup.jl")
    @test m._cli_bound_before_setup === DistSSHRun.cli_project_root
    Base.include(m, setup_jl)
    @test m.resolve_remote_project_root("/tmp/App.jl") ==
        DistSSHRun.resolve_remote_project_root("/tmp/App.jl")
    @test isdefined(m, :setup_main)
end
