using Test

@testset "(@main) dispatch" begin
    # `julia -m DistSSHRun` invokes this module's `main`.
    function _main_capture(args)
        mktemp() do out_path, out_io
            mktemp() do err_path, err_io
                code = withenv("DISTSSHKIT_CLI_SUBCOMMAND_DONE" => "") do
                    redirect_stdout(out_io) do
                        redirect_stderr(err_io) do
                            DistSSHRun.main(args)
                        end
                    end
                end
                flush(out_io)
                flush(err_io)
                return code, read(out_path, String), read(err_path, String)
            end
        end
    end

    # Same stream and entry as `_main`: stderr, and no color while stdout is not a TTY.
    function _root_page()
        buf = IOBuffer()
        redirect_stdout(devnull) do
            DistSSHRun.with_cli_entry(:DistSSHRun) do
                DistSSHRun.print_kit_root_usage(buf)
            end
        end
        return String(take!(buf))
    end

    function _go_page()
        buf = IOBuffer()
        redirect_stdout(devnull) do
            DistSSHRun.with_cli_entry(:DistSSHRun) do
                DistSSHRun.show_go_usage(; io = buf)
            end
        end
        return String(take!(buf))
    end

    let (code, _, err) = _main_capture(String[])
        @test code == 1
        @test occursin("Usage", err)
        @test occursin("julia -m DistSSHRun <command>", err)
    end
    # Unknown first token must fail, not exit 0.
    let (code, _, err) = _main_capture(["bogus"])
        @test code == 1
        @test occursin("Unknown subcommand: bogus", err)
    end
    let (code, _, err) = _main_capture(["map_echo.jl"])
        @test code == 1
        @test occursin("does not infer go / ride / drive", err)
        @test occursin("go SCRIPT.jl", err)
        @test !occursin("Unknown subcommand", err)
    end
    let (code, _, err) = _main_capture(["parent:2", "job.jl"])
        @test code == 1
        @test occursin("does not infer go / ride / drive", err)
    end
    let (code, _, err) = _main_capture(["rysnc", "child:host1"])
        @test code == 1
        @test occursin("Unknown subcommand: rysnc", err)
    end
    let (code, _, err) = _main_capture(["--help"])
        @test code == 0
        @test occursin("Usage", err)
        @test occursin("julia -m DistSSHRun <command>", err)
        @test occursin("progress", err)
    end
    let (code, out, _) = _main_capture(["--version"])
        @test code == 0
        @test occursin("DistSSHRun $(DistSSHRun.dist_ssh_kit_version())", out)
    end
    let (code, _, err) = _main_capture(["help"])
        @test code == 0
        @test occursin("julia -m DistSSHRun <command>", err)
    end
    let (code, out, _) = _main_capture(["-V"])
        @test code == 0
        @test occursin("DistSSHRun $(DistSSHRun.dist_ssh_kit_version())", out)
    end

    @testset "refused rsync and prune paths print Error" begin
        for mode in ("--ship-tree", "--prune")
            let (code, out, err) = _main_capture(
                    [
                        "setup", mode, "--remote-path", "/", "child:host1",
                    ]
                )
                shown = out * err
                @test code == 1
                @test occursin("Error:", shown)
                @test occursin("refusing remote path", shown)
                @test !occursin("Stacktrace", shown)
            end
        end
    end

    # Subcommand --help / --version load `src/cli/*.jl` in-process (no SSH / addprocs).
    @testset "subcommand help and version" begin
        for cmd in ("drive", "go", "plan", "ride", "setup", "size", "pool")
            let (code, out, err) = _main_capture([cmd, "--help"])
                combined = out * err
                @test code == 0
                @test occursin("Usage", combined)
                @test occursin("DistSSHRun $cmd", combined)
                @test occursin("-m DistSSHRun", combined)
                @test occursin(cmd, lowercase(combined))
            end
            let (code, out, _) = _main_capture([cmd, "--version"])
                @test code == 0
                @test occursin("DistSSHRun $(DistSSHRun.dist_ssh_kit_version())", out)
            end
        end
        let (code, out, _) = _main_capture(["progress", "--help"])
            @test code == 0
            @test occursin("DistSSHRun progress", out)
            @test occursin("-m DistSSHRun progress", out)
            @test occursin("kit.progress", out)
        end
        let (code, out, _) = _main_capture(["up", "-h"])
            @test code == 0
            @test occursin("DistSSHRun up", out)
            @test occursin("-m DistSSHRun up", out)
            @test !occursin("qhost", out)
        end
    end

    @testset "help <command> is <command> --help" begin
        for cmd in (
                "drive", "go", "plan", "ride", "setup", "size", "pool", "up", "demo", "progress",
            )
            direct = _main_capture([cmd, "--help"])
            via = _main_capture(["help", cmd])
            @test via[1] == 0
            @test via == direct
        end
        let via = _main_capture(["help", "go", "--hosts", "parent:1"])
            direct = _main_capture(["go", "--hosts", "parent:1", "--help"])
            @test via[1] == 0
            @test via == direct
            @test occursin("-h, --help", via[2])
        end
        let via = _main_capture(["help", "setup", "--check"])
            direct = _main_capture(["setup", "--help", "--check"])
            @test via[1] == 0
            @test via == direct
            @test occursin("Usage", via[2])
        end
        let (code, out, err) = _main_capture(["demo", "help"])
            via = _main_capture(["help", "demo"])
            direct = _main_capture(["demo", "--help"])
            @test code == 0
            @test (code, out, err) == via == direct
            @test occursin("Usage", out)
            @test !occursin("Unknown demo command", out * err)
        end
        let via = _main_capture(["help", "bogus"])
            direct = _main_capture(["bogus"])
            @test via[1] == 1
            @test via == direct
            @test occursin(DistSSHRun.unknown_subcommand_message("bogus"), via[3])
            @test via[3] == direct[3]
            @test occursin("Unknown subcommand: bogus", via[3])
            @test !occursin("Unknown subcommand: help", via[3])
        end
        let via = _main_capture(["help", "go", "--help"])
            direct = _main_capture(["go", "--help", "--help"])
            @test via[1] == 0
            @test via == direct
            @test via[2] == _go_page()
            @test via[3] == ""
        end
        let (code, _, err) = _main_capture(["help", "map_echo.jl"])
            @test code == 1
            @test occursin("got \"map_echo.jl\"", err)
            @test occursin("does not infer go / ride / drive", err)
            @test !occursin("Unknown subcommand", err)
        end
        let (code, _, err) = _main_capture(["help", "parent:2", "job.jl"])
            @test code == 1
            @test occursin("got \"parent:2\"", err)
        end
        for args in (String[], ["help"], ["-h"], ["--help"])
            let (code, _, err) = _main_capture(args)
                @test code == (isempty(args) ? 1 : 0)
                @test occursin("Run `julia -m DistSSHRun help <command>` for flags.", err)
                @test !occursin("<command> -h", err)
            end
        end
        let via = _main_capture(["help", "drive", "--help"])
            direct = _main_capture(["drive", "--help", "--help"])
            @test via == direct
        end
    end

    @testset "rejection sentences" begin
        @test DistSSHRun.unknown_subcommand_message("bogus") ==
            "Unknown subcommand: bogus"
        @test DistSSHRun.no_command_message("map_echo.jl") ==
            "No command (got \"map_echo.jl\"). Kit does not infer go / ride / drive."
        @test DistSSHRun.RUN_SUBCOMMAND_EXPECTATION ==
            "Expected: setup | up | go | ride | drive | plan | size | pool | demo | progress"
        @test DistSSHRun.NO_COMMAND_HINT_LINES == (
            "  go SCRIPT.jl      as-is complete job (timing without rewrite)",
            "  ride … SCRIPT.jl  experimental map / filter",
            "  drive … SCRIPT.jl Distributed",
            "  plan SCRIPT.jl    inspect; do not run",
        )
        for name in (
                :unknown_subcommand_message,
                :no_command_message,
                :print_rejected_command,
                :NO_COMMAND_HINT_LINES,
                :RUN_SUBCOMMAND_EXPECTATION,
            )
            @test Base.ispublic(DistSSHRun, name)
            @test !Base.isexported(DistSSHRun, name)
        end
        buf = IOBuffer()
        DistSSHRun.print_rejected_command("bogus"; script = false, io = buf)
        text = String(take!(buf))
        @test occursin("Unknown subcommand: bogus\n", text)
        @test occursin(DistSSHRun.RUN_SUBCOMMAND_EXPECTATION * "\n", text)
        @test !occursin("Usage", text)
    end

    @testset "help-only argv is the root page" begin
        page = _root_page()
        for args in (
                ["help", "--help"],
                ["help", "-h"],
                ["help", "help"],
                ["--help", "help"],
                ["-h", "--help"],
                ["--help", "-h", "help"],
            )
            let (code, out, err) = _main_capture(args)
                @test code == 0
                @test out == ""
                @test err == page
                @test !occursin("Unknown subcommand", err)
            end
        end
    end

    @testset "_run_kit_cli_script restores ARGS and re-reads project root" begin
        saved = copy(ARGS)
        try
            empty!(ARGS)
            append!(ARGS, ["sentinel-a", "sentinel-b"])
            let (code, _, _) = _main_capture(["size", "--version"])
                @test code == 0
            end
            @test ARGS == ["sentinel-a", "sentinel-b"]
        finally
            empty!(ARGS)
            append!(ARGS, saved)
        end

        _with_tempdir() do root_a::String
            _with_tempdir() do root_b::String
                proj_a = joinpath(root_a, "ProjAlpha")
                proj_b = joinpath(root_b, "ProjBeta")
                mkpath(proj_a)
                mkpath(proj_b)
                write(joinpath(proj_a, "Project.toml"), "name = \"ProjAlpha\"\n")
                write(joinpath(proj_b, "Project.toml"), "name = \"ProjBeta\"\n")
                script_a = joinpath(proj_a, "job.jl")
                script_b = joinpath(proj_b, "job.jl")
                write(script_a, "true\n")
                write(script_b, "true\n")

                let (code_a, out_a, err_a) = withenv("DISTRIBUTED_PROJECT_ROOT" => proj_a) do
                        _main_capture(["plan", "parent", "--gb-per-worker", "0.5", script_a])
                    end
                    @test code_a == 0
                    @test occursin("ProjAlpha", out_a * err_a)
                end
                let (code_b, out_b, err_b) = withenv("DISTRIBUTED_PROJECT_ROOT" => proj_b) do
                        _main_capture(["plan", "parent", "--gb-per-worker", "0.5", script_b])
                    end
                    @test code_b == 0
                    @test occursin("ProjBeta", out_b * err_b)
                    @test !occursin("ProjAlpha", out_b * err_b)
                end
            end
        end
    end

    # Not `_main_capture`: that `withenv` clears the handshake flag between calls.
    @testset "second main() in the same process (#184)" begin
        had = get(ENV, "DISTSSHKIT_CLI_SUBCOMMAND_DONE", nothing)
        function _capture_main(args)
            mktemp() do out_path, out_io
                mktemp() do err_path, err_io
                    code = redirect_stdout(out_io) do
                        redirect_stderr(err_io) do
                            return DistSSHRun.main(args)
                        end
                    end
                    flush(out_io)
                    flush(err_io)
                    return code, read(out_path, String), read(err_path, String)
                end
            end
        end
        try
            delete!(ENV, "DISTSSHKIT_CLI_SUBCOMMAND_DONE")
            ver = DistSSHRun.dist_ssh_kit_version()
            let (code, out, _) = _capture_main(["drive", "--version"])
                @test code == 0
                @test occursin("DistSSHRun $ver", out)
                @test !haskey(ENV, "DISTSSHKIT_CLI_SUBCOMMAND_DONE")
            end
            let (code, out, _) = _capture_main(["go", "--version"])
                @test code == 0
                @test occursin("DistSSHRun $ver", out)
                @test !haskey(ENV, "DISTSSHKIT_CLI_SUBCOMMAND_DONE")
            end
            mktempdir() do dir
                missing = joinpath(dir, "missing.jl")
                @test_throws ErrorException redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        DistSSHRun.main(["drive", missing])
                    end
                end
                @test !haskey(ENV, "DISTSSHKIT_CLI_SUBCOMMAND_DONE")
            end
            let (code, out, _) = _capture_main(["--version"])
                @test code == 0
                @test occursin("DistSSHRun $ver", out)
            end
        finally
            if had === nothing
                delete!(ENV, "DISTSSHKIT_CLI_SUBCOMMAND_DONE")
            else
                ENV["DISTSSHKIT_CLI_SUBCOMMAND_DONE"] = had
            end
        end
    end
end
