using Test

include(joinpath(@__DIR__, "..", "..", "..", ".github", "downstream_public.jl"))

@testset "downstream public names" begin
    @test Base.ispublic(DistSSHRun, :main)
    @test !Base.isexported(DistSSHRun, :main)
    @test length(DOWNSTREAM_PUBLIC_ALLOW) == 37
    @test !Base.ispublic(DistSSHRun, :_main)
    @test !Base.ispublic(DistSSHRun.DistSSHBase, :_scp_cmd)
    @test !Base.ispublic(DistSSHRun, :kit_confirm!)

    mktempdir() do tmp
        src = joinpath(tmp, "src")
        mkpath(src)
        write(joinpath(src, "ok.jl"), "DistSSHRun.print_cli_error(\"x\")\n")
        write(joinpath(src, "field.jl"), "DistSSHRun.KitProcess.run_dir\n")
        write(joinpath(src, "allow.jl"), "DistSSHRun.print_header(\"t\")\n")
        write(joinpath(src, "imp.jl"), "using DistSSHRun.DistSSHBase: _ssh_host_args\n")
        write(joinpath(src, "pkg.jl"), "import DistSSHRun\n")
        @test isempty(downstream_public_failures(src))

        write(joinpath(src, "bad.jl"), "DistSSHRun._main(String[])\n")
        fails = downstream_public_failures(src)
        @test length(fails) == 1
        @test fails[1] == "bad.jl:1: DistSSHRun._main is not public"
        rm(joinpath(src, "bad.jl"))

        write(joinpath(src, "baseimp.jl"), "using DistSSHRun.DistSSHBase: _scp_cmd\n")
        fails = downstream_public_failures(src)
        @test fails == ["baseimp.jl:1: DistSSHRun.DistSSHBase._scp_cmd is not public"]
        rm(joinpath(src, "baseimp.jl"))

        write(
            joinpath(src, "bound.jl"),
            """
            const _QUALIFIED = (
                :kit_confirm!,
            )
            for _n in _QUALIFIED
                _bind!(DistSSHRun, _n; export_name = false)
            end
            """,
        )
        fails = downstream_public_failures(src)
        @test length(fails) == 1
        @test startswith(fails[1], "bound.jl:")
        @test occursin("DistSSHRun.kit_confirm! is not public", fails[1])
        rm(joinpath(src, "bound.jl"))

        testdir = joinpath(tmp, "test")
        mkpath(testdir)
        write(joinpath(testdir, "skip.jl"), "DistSSHRun._main(String[])\n")
        @test isempty(downstream_public_failures(src))
    end

    mktempdir() do tmp
        src = joinpath(tmp, "src")
        mkpath(src)
        write(joinpath(src, "ok.jl"), "DistSSHRun.print_cli_error(\"x\")\n")
        allow = Dict{Tuple{Symbol, Symbol}, Int}(
            (:DistSSHRun, :print_cli_error) => 201,
        )
        fails = downstream_public_failures(src; allow = allow)
        @test fails == ["allowlist: DistSSHRun.print_cli_error is public; remove the #201 entry"]
    end
end
