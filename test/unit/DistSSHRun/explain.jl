using Test

@testset "explain surfaces" begin
    @testset "script not found" begin
        _with_tempdir() do tmp
            missing = joinpath(tmp, "nope.jl")
            msg = DistSSHRun.explain_script_not_found(missing, tmp; surface = :api)
            @test occursin("Script not found", msg)
            @test occursin(missing, msg)
            @test !occursin("install_demos", msg)

            demo = joinpath(tmp, "demos", "with_kit", "rho_sweep.jl")
            demo_msg = DistSSHRun.explain_script_not_found(demo, tmp; surface = :api)
            @test occursin("install_demos", demo_msg)

            headed = DistSSHRun.explain_script_not_found(
                demo, tmp; surface = :api, headline = "script not found: x",
            )
            @test startswith(headed, "script not found: x")
            @test occursin("DistSSHRun.install_demos(; family=", headed)

            kit_wrong = DistSSHRun.explain_script_not_found(
                joinpath(_kit_root(), "demos", "square_file.jl"),
                _kit_root(),
            )
            @test occursin("demos/with_kit/square_file.jl", kit_wrong)

            missing_kit = joinpath(tmp, "demos", "with_kit", "square_file.jl")
            cli = DistSSHRun.explain_script_not_found(missing_kit, tmp; surface = :cli)
            @test occursin("demo install", cli)
            @test !occursin("install_demos()", cli)
            api = DistSSHRun.explain_script_not_found(missing_kit, tmp; surface = :api)
            @test occursin("DistSSHRun.install_demos(; family=", api)
            @test !occursin("demo install", api)

            custom = joinpath(tmp, "demos", "with_kit", "rho_sweep.jl")
            @test occursin("./demos/ is missing", DistSSHRun.explain_script_not_found(custom, tmp))
            mkpath(joinpath(tmp, "demos", "with_kit"))
            after = DistSSHRun.explain_script_not_found(custom, tmp; surface = :api)
            @test occursin("no such file under ./demos/", after)
            @test occursin("DistSSHRun.list_demos()", after)
        end
    end

    @testset "session wiring" begin
        _with_tempdir() do tmp
            session = DistSSHRun.KitSession(project = tmp, workers = String[], quiet = true)
            @test DistSSHRun.hint_surface(session) === :api
            @test session.cli_session.hint_surface === :api

            err = try
                with_kit_verbosity(:progress) do
                    DistSSHRun.sync!(session)
                end
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("workers=", sprint(showerror, err))
            @test occursin("Hint:", sprint(showerror, err))

            @test DistSSHRun.KitCliSession().hint_surface === :cli
        end
    end
end
