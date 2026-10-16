using Test

@testset "CLI subcommands in-process entrypoints" begin
    function _cli_capture(f::Function)
        mktemp() do out_path, out_io
            mktemp() do err_path, err_io
                code = withenv(
                    "DISTSSHKIT_CLI_SUBCOMMAND_DONE" => "",
                    "DISTSSHKIT_YES" => nothing,
                ) do
                    redirect_stdin(devnull) do
                        redirect_stdout(out_io) do
                            redirect_stderr(err_io) do
                                f()
                            end
                        end
                    end
                end
                flush(out_io)
                flush(err_io)
                return code, read(out_path, String), read(err_path, String)
            end
        end
    end

    @testset "go, ride, drive, plan empty args and error paths" begin
        let (code, out, err) = _cli_capture(() -> DistSSHRun.go(String[]))
            @test code == 0
            @test occursin("Usage", out * err)
        end
        let (code, out, err) = _cli_capture(() -> DistSSHRun.run_ride(String[]))
            @test code == 0
            @test occursin("Usage", out * err)
        end
        let (code, out, err) = _cli_capture(() -> DistSSHRun.drive(String[]))
            @test code == 0
            @test occursin("Usage", out * err)
        end
        let (code, out, err) = _cli_capture(() -> DistSSHRun.run_plan(String[]))
            @test code == 0
            @test occursin("Usage", out * err)
        end
        let (code, _, _) = _cli_capture(() -> DistSSHRun.run_plan(["/no/such/script.jl"]))
            @test code == 1
        end
        let (code, _, _) = _cli_capture(() -> DistSSHRun.run_ride(["/no/such/script.jl"]))
            @test code == 1
        end
    end

    @testset "size, pool, up, progress entrypoints" begin
        let (code, out, err) = _cli_capture(() -> DistSSHRun.run_size(String[]))
            @test code == 0
            @test occursin("Usage", out * err)
        end
        let (code, out, err) = _cli_capture(() -> DistSSHRun.run_pool(String[]))
            @test code == 0
            @test occursin("Usage", out * err)
        end
        let (code, out, err) = _cli_capture(() -> DistSSHRun.up(["--version"]))
            @test code == 0
            @test occursin(string(DistSSHRun.dist_ssh_kit_version()), out * err)
        end
        let (code, out, err) = _cli_capture(() -> DistSSHRun.up(["--bogus"]))
            @test code == 1
            @test occursin("Error:", out * err)
        end
        let (code, out, err) = _cli_capture(() -> DistSSHRun.up(["add", "1.13", "badhost"]))
            @test code == 1
            @test occursin("Error:", out * err)
        end
        let (code, out, err) = _cli_capture(() -> DistSSHRun.progress(["--help"]))
            @test code == 0
            @test occursin("progress", out * err)
        end
        let (code, _, _) = _cli_capture(() -> DistSSHRun.progress(["/no/such/dir"]))
            @test code == 1
        end
    end

    @testset "consecutive calls across project switches" begin
        _with_tempdir() do root_a::String
            _with_tempdir() do root_b::String
                proj_a = joinpath(root_a, "SwitchOne")
                proj_b = joinpath(root_b, "SwitchTwo")
                mkpath(proj_a)
                mkpath(proj_b)
                write(joinpath(proj_a, "Project.toml"), "name = \"SwitchOne\"\n")
                write(joinpath(proj_b, "Project.toml"), "name = \"SwitchTwo\"\n")
                script_a = joinpath(proj_a, "job.jl")
                script_b = joinpath(proj_b, "job.jl")
                write(script_a, "println(\"ok_a\")\n")
                write(script_b, "println(\"ok_b\")\n")

                withenv("DISTRIBUTED_PROJECT_ROOT" => nothing) do
                    let (code_a, out_a, err_a) = cd(proj_a) do
                            _cli_capture(
                                () -> DistSSHRun.run_plan(
                                    ["parent", "--gb-per-worker", "0.5", script_a],
                                ),
                            )
                        end
                        @test code_a == 0
                        @test occursin("SwitchOne", out_a * err_a)
                    end

                    let (code_b, out_b, err_b) = cd(proj_b) do
                            _cli_capture(
                                () -> DistSSHRun.run_plan(
                                    ["parent", "--gb-per-worker", "0.5", script_b],
                                ),
                            )
                        end
                        @test code_b == 0
                        @test occursin("SwitchTwo", out_b * err_b)
                        @test !occursin("SwitchOne", out_b * err_b)
                    end
                end
            end
        end
    end
end
