using Test

# clap arg_required_else_help: stream and exit code per command entry.
@testset "CLI exit conventions (clap arg_required_else_help)" begin
    function _capture(f::Function)
        mktemp() do out_path, out_io
            mktemp() do err_path, err_io
                code = withenv(
                    "DISTSSH_CLI_SUBCOMMAND_DONE" => "",
                    "DISTSSH_YES" => nothing,
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

    USAGE_EXIT = 2

    for (cmd, bare, help_argv, help_needle) in (
            (:go, () -> DistSSHRun.go(String[]), ["--help"], "SCRIPT.jl"),
            (:drive, () -> DistSSHRun.drive(String[]), ["--help"], "drive"),
            (:up, () -> DistSSHRun.up(String[]), ["--help"], "up"),
            (:setup, () -> DistSSHRun.setup(String[]), ["--help"], "ship-tree"),
        )
        @testset "$cmd bare" begin
            let (code, out, err) = _capture(bare)
                @test code == USAGE_EXIT
                @test isempty(out)
                @test occursin("Usage", err) || occursin(help_needle, err)
            end
        end
        @testset "$cmd --help" begin
            let (code, out, err) = _capture(
                    () -> cmd == :go ? DistSSHRun.go(help_argv) :
                        cmd == :drive ? DistSSHRun.drive(help_argv) :
                        cmd == :up ? DistSSHRun.up(help_argv) :
                        DistSSHRun.setup(help_argv)
                )
                @test code == 0
                @test occursin("Usage", out) || occursin(help_needle, out)
                @test !occursin("Usage", err)
            end
        end
    end

    let (code, out, err) = _capture(() -> DistSSHRun.main(String[]))
        @test code == USAGE_EXIT
        @test occursin("Usage", err)
        @test isempty(out)
    end

    let (code, out, _) = _capture(() -> DistSSHRun.main(["--help"]))
        @test code == 0
        @test occursin("Usage", out)
    end

    @testset "hostinfo bare keeps default output" begin
        let (code, out, err) = _capture(() -> DistSSHRun.run_hostinfo(String[]))
            @test code == 0
            @test occursin("Hostinfo:", out * err)
        end
    end

    @testset "usage errors exit 2" begin
        let (code, _, err) = _capture(() -> DistSSHRun.run_hostinfo(["--nope"]))
            @test code == USAGE_EXIT
            @test occursin("unknown hostinfo option", err)
        end
        let (code, _, err) = _capture(() -> DistSSHRun.run_pool(["--nope"]))
            @test code == USAGE_EXIT
            @test occursin("unknown pool option", err)
        end
        let (code, _, err) = _capture(() -> DistSSHRun.up(["--bogus"]))
            @test code == USAGE_EXIT
            @test occursin("Error:", err)
        end
        let (code, _, err) = _capture(
                () -> DistSSHRun.go(["--ship-tree", "1*h1", "job.jl"]),
            )
            @test code == USAGE_EXIT
            @test occursin("ship-tree was removed", err)
        end
    end

    @testset "removed ride subcommand" begin
        let (code, _, err) = _capture(() -> DistSSHRun.main(["ride", "job.jl"]))
            @test code == USAGE_EXIT
            @test occursin(DistSSHRun.REMOVED_RIDE_SUBCOMMAND_HINT, err)
        end
    end

    @testset "setup requirements" begin
        let (code, out, _) = _capture(() -> DistSSHRun.setup(["requirements"]))
            @test code == 0
            @test occursin("ship-tree", out)
        end
    end
end
