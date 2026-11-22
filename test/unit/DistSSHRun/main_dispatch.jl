using Test

@testset "(@main) dispatch" begin
    saved_done = get(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE", nothing)
    try
        # `julia -m DistSSHRun` invokes this module's `main`.
        function _main_capture(args)
            mktemp() do out_path, out_io
                mktemp() do err_path, err_io
                    code = withenv("DISTSSH_CLI_SUBCOMMAND_DONE" => "") do
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
            @test code == 2
            @test occursin("Usage", err)
            @test occursin("julia -m DistSSHRun <command>", err)
        end
        # Unknown first token must fail, not exit 0.
        let (code, _, err) = _main_capture(["bogus"])
            @test code == 2
            @test occursin("Unknown subcommand: bogus", err)
        end
        let (code, _, err) = _main_capture(["size"])
            @test code == 2
            @test occursin("Unknown subcommand: size", err)
            @test occursin("hostinfo", err)
            @test !occursin("Stacktrace", err)
        end
        let (code, _, err) = _main_capture(["map_echo.jl"])
            @test code == 2
            @test occursin("does not infer go or drive", err)
            @test occursin("go SCRIPT.jl", err)
            @test !occursin("Unknown subcommand", err)
        end
        let (code, _, err) = _main_capture(["--head-workers", "2", "job.jl"])
            @test code == 2
            @test occursin("Unknown subcommand: --head-workers", err)
        end
        let (code, _, err) = _main_capture(["rysnc", "host1"])
            @test code == 2
            @test occursin("Unknown subcommand: rysnc", err)
        end
        let (code, out, err) = _main_capture(["--help"])
            @test code == 0
            @test occursin("Usage", out)
            @test occursin("julia -m DistSSHRun <command>", out)
            @test occursin("progress", out)
            @test isempty(err)
        end
        let (code, out, _) = _main_capture(["--version"])
            @test code == 0
            @test occursin("DistSSHRun $(DistSSHRun.dist_ssh_kit_version())", out)
        end
        let (code, out, err) = _main_capture(["help"])
            @test code == 0
            @test occursin("julia -m DistSSHRun <command>", out)
            @test isempty(err)
        end
        let (code, out, _) = _main_capture(["-V"])
            @test code == 0
            @test occursin("DistSSHRun $(DistSSHRun.dist_ssh_kit_version())", out)
        end

        @testset "refused ship-tree and prune paths print Error" begin
            for mode in ("ship-tree", "prune")
                let (code, out, err) = _main_capture(
                        [
                            "setup", mode, "--deploy-root", "/", "host1",
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
            for cmd in ("drive", "go", "setup", "hostinfo", "pool")
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
                    "drive", "go", "setup", "hostinfo", "pool", "up", "demo", "progress",
                )
                direct = _main_capture([cmd, "--help"])
                via = _main_capture(["help", cmd])
                @test via[1] == 0
                @test via == direct
            end
            let via = _main_capture(["help", "go", "--head-slots", "1", "--help"])
                direct = _main_capture(["go", "--head-slots", "1", "--help"])
                @test via[1] == 0
                @test via == direct
                @test occursin("-h, --help", via[2])
            end
            let via = _main_capture(["help", "setup", "check"])
                direct = _main_capture(["setup", "--help", "check"])
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
                @test via[1] == 2
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
                @test code == 2
                @test occursin("got \"map_echo.jl\"", err)
                @test occursin("does not infer go or drive", err)
                @test !occursin("Unknown subcommand", err)
            end
            let (code, _, err) = _main_capture(["help", "--head-workers", "2", "job.jl"])
                @test code == 2
                @test occursin("head-workers", err) || occursin("local-workers", err) ||
                    occursin("unknown", lowercase(err))
            end
            for args in (String[], ["help"], ["-h"], ["--help"])
                let (code, out, err) = _main_capture(args)
                    @test code == (isempty(args) ? 2 : 0)
                    if isempty(args)
                        @test occursin("Usage", err)
                        @test isempty(out)
                    else
                        @test occursin(
                            "Run `julia -m DistSSHRun help <command>` for flags.",
                            out,
                        )
                        @test isempty(err)
                        @test !occursin("<command> -h", out)
                    end
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
                "No command (got \"map_echo.jl\"). Kit does not infer go or drive."
            @test DistSSHRun.RUN_SUBCOMMAND_EXPECTATION ==
                "Expected: setup | doctor | up | go | drive | hostinfo | pool | demo | progress"
            @test DistSSHRun.NO_COMMAND_HINT_LINES == (
                "  go SCRIPT.jl      as-is complete job (timing without rewrite)",
                "  drive … SCRIPT.jl Distributed",
            )
            @test DistSSHRun.REMOVED_RIDE_SUBCOMMAND_HINT ==
                "ride was removed; use drive with pmap"
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
            buf_ride = IOBuffer()
            DistSSHRun.print_rejected_command("ride"; script = false, io = buf_ride)
            ride_text = String(take!(buf_ride))
            @test occursin(DistSSHRun.REMOVED_RIDE_SUBCOMMAND_HINT, ride_text)
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
                    @test err == ""
                    @test out == page
                    @test !occursin("Unknown subcommand", out)
                end
            end
        end

        @testset "_run_kit_cli_script restores ARGS and re-reads project root" begin
            saved = copy(ARGS)
            try
                empty!(ARGS)
                append!(ARGS, ["sentinel-a", "sentinel-b"])
                let (code, _, _) = _main_capture(["hostinfo", "--version"])
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

                    let (code_a, out_a, err_a) = withenv("DISTRIBUTED_PROJECT_ROOT" => proj_a) do
                            _main_capture(["hostinfo"])
                        end
                        @test code_a == 0
                        @test occursin("ProjAlpha", out_a * err_a)
                    end
                    let (code_b, out_b, err_b) = withenv("DISTRIBUTED_PROJECT_ROOT" => proj_b) do
                            _main_capture(["hostinfo"])
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
            had = get(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE", nothing)
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
                delete!(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE")
                ver = DistSSHRun.dist_ssh_kit_version()
                let (code, out, _) = _capture_main(["drive", "--version"])
                    @test code == 0
                    @test occursin("DistSSHRun $ver", out)
                    @test !haskey(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE")
                end
                let (code, out, _) = _capture_main(["go", "--version"])
                    @test code == 0
                    @test occursin("DistSSHRun $ver", out)
                    @test !haskey(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE")
                end
                mktempdir() do dir
                    missing = joinpath(dir, "missing.jl")
                    code = redirect_stdout(devnull) do
                        redirect_stderr(devnull) do
                            DistSSHRun.main(["drive", "--head-workers", "1", missing])
                        end
                    end
                    @test code != 0
                    @test !haskey(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE")
                end
                let (code, out, _) = _capture_main(["--version"])
                    @test code == 0
                    @test occursin("DistSSHRun $ver", out)
                end
            finally
                if had === nothing
                    delete!(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE")
                else
                    ENV["DISTSSH_CLI_SUBCOMMAND_DONE"] = had
                end
            end
        end
    finally
        if saved_done === nothing
            delete!(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE")
        else
            ENV["DISTSSH_CLI_SUBCOMMAND_DONE"] = saved_done
        end
    end
end
