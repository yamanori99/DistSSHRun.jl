using Test

include(joinpath(@__DIR__, "..", "..", "..", ".github", "downstream_public.jl"))

@testset "downstream public names" begin
    @test Base.ispublic(DistSSHRun, :main)
    @test !Base.isexported(DistSSHRun, :main)
    @test length(DOWNSTREAM_PUBLIC_ALLOW) == 0
    @test Base.ispublic(DistSSHRun, :dist_ssh_kit_version)
    @test Base.ispublic(DistSSHRun, :parse_pool_args)
    @test Base.ispublic(DistSSHRun, :show_pool_usage)
    @test Base.ispublic(DistSSHRun, :resolve_output_dir!)
    @test !Base.isexported(DistSSHRun, :resolve_output_dir!)
    @test Base.ispublic(DistSSHRun.DistSSHBase, :process_start_key)
    @test !isdefined(DistSSHRun, :kit_process_start_key)
    @test Base.ispublic(DistSSHRun.DistSSHBase.CLI, :print_header)
    @test Base.ispublic(DistSSHRun.DistSSHBase.CLI, :print_warn)
    @test Base.ispublic(DistSSHRun.DistSSHBase.CLI, :cli_println)
    @test Base.ispublic(DistSSHRun.DistSSHBase.CLI, :writeln_field)
    @test Base.ispublic(DistSSHRun.DistSSHBase.CLI, :cli_confirm)
    @test Base.ispublic(DistSSHRun.DistSSHBase.CLI, :progress_done!)
    @test Base.ispublic(DistSSHRun.DistSSHBase.CLI, :progress_latest)
    @test Base.ispublic(DistSSHRun.DistSSHBase.CLI, :CURRENT_PROGRESS)
    @test Base.ispublic(DistSSHRun.DistSSHBase.CLI, :PROGRESS_SUSPEND)
    @test Base.ispublic(DistSSHRun.DistSSHBase.CLI, :ProgressState)
    @test !Base.ispublic(DistSSHRun, :_main)
    @test !Base.ispublic(DistSSHRun.DistSSHBase, :_scp_cmd)
    @test !Base.ispublic(DistSSHRun, :cli_confirm!)

    mktempdir() do tmp
        src = joinpath(tmp, "src")
        mkpath(src)
        write(joinpath(src, "ok.jl"), "DistSSHRun.print_cli_error(\"x\")\n")
        write(
            joinpath(src, "component_id.jl"),
            "DistSSHRun.DistSSHBase.src_component_digest(@__DIR__, (:x.jl))\n"
        )
        write(
            joinpath(src, "shipread.jl"),
            """
            DistSSHRun.result_run_dir(kp)
            DistSSHRun.result_content_tree_hash(result)
            DistSSHRun.result_ship_id(result)
            DistSSHRun.ship_send_list(root)
            """
        )
        write(joinpath(src, "field.jl"), "DistSSHRun.DetachedProcess.run_dir\n")
        write(joinpath(src, "pkg.jl"), "import DistSSHRun\n")
        write(joinpath(src, "cli.jl"), "DistSSHRun.DistSSHBase.CLI.print_header(\"t\")\n")
        @test isempty(downstream_public_failures(src))

        write(joinpath(src, "allow.jl"), "DistSSHRun.print_header(\"t\")\n")
        fails = downstream_public_failures(src)
        @test fails == ["allow.jl:1: DistSSHRun.print_header is not public"]
        rm(joinpath(src, "allow.jl"))

        write(joinpath(src, "imp.jl"), "using DistSSHRun.DistSSHBase: _ssh_host_args\n")
        fails = downstream_public_failures(src)
        @test fails == ["imp.jl:1: DistSSHRun.DistSSHBase._ssh_host_args is not public"]
        rm(joinpath(src, "imp.jl"))

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
                :cli_confirm!)
            for _n in _QUALIFIED
                _bind!(DistSSHRun, _n; export_name = false)
            end
            """
        )
        fails = downstream_public_failures(src)
        @test length(fails) == 1
        @test startswith(fails[1], "bound.jl:")
        @test occursin("DistSSHRun.cli_confirm! is not public", fails[1])
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
            (:DistSSHRun, :print_cli_error) => 201
        )
        fails = downstream_public_failures(src; allow = allow, validate_allowlist_size = false)
        @test fails == ["allowlist: DistSSHRun.print_cli_error is public; remove the #201 entry"]
    end
end
