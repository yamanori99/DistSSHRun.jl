using Test

# Oracle: in-process `setup` CLI entry (`src/cli/setup.jl`) for help-like
# modes and host-validation failure. Fake ssh/rsync success paths stay in
# integration/setup/exit.jl.

@testset "setup CLI entry" begin
    function _setup_capture(args)
        mktemp() do out_path, out_io
            mktemp() do err_path, err_io
                code = withenv(
                    "DISTSSHKIT_CLI_SUBCOMMAND_DONE" => "",
                    "DISTSSHKIT_YES" => nothing,
                ) do
                    redirect_stdin(devnull) do
                        redirect_stdout(out_io) do
                            redirect_stderr(err_io) do
                                DistSSHRun.setup(args)
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

    let (code, out, err) = _setup_capture(["--not-a-flag"])
        shown = out * err
        @test code == 1
        @test occursin("unknown setup option: --not-a-flag", shown)
        @test occursin("help setup", shown)
        @test !occursin("--help", shown)
        @test !occursin("Modes (one per run)", shown)
    end
    let (code, out, err) = _setup_capture(["--help", "--check", "--sync"])
        shown = out * err
        @test code == 1
        @test occursin("more than one mode (--check and --sync)", shown)
        @test occursin("help setup", shown)
        @test !occursin("--help", shown)
    end
    let (code, out, _) = _setup_capture(String[])
        @test code == 0
        @test occursin("Recommended", out)
        @test occursin("--rsync", out)
    end
    let (code, out, _) = _setup_capture(["--requirements"])
        @test code == 0
        @test occursin("--instantiate", out)
    end
    let (code, out, err) = _setup_capture(["--delete", "parent"])
        @test code == 1
        @test occursin("only for up", out * err)
    end
    let (code, out, err) = _setup_capture(["--delete", "host1"])
        @test code == 1
        combined = out * err
        @test occursin("child:NAME", combined) || occursin("parent[:N]", combined)
    end
    let (code, out, err) = withenv(
            "DISTSSHKIT_TEST" => "1",
            "DISTSSHKIT_TEST_SSH" => "/no/such/fake-ssh.jl",
        ) do
            _setup_capture(["--delete", "--yes", "child:host1"])
        end
        combined = out * err
        @test code == 1
        @test occursin("do not authorize", combined)
        @test occursin("--confirm-path", combined)
        @test occursin("help setup", combined)
        @test !occursin("--help", combined)
        @test !occursin("SSH preflight failed", combined)
    end
    let (code, out, err) = _setup_capture(
            ["--delete", "--yes", "--confirm-path", "~/nope", "child:host1"],
        )
        combined = out * err
        @test code == 1
        @test occursin("does not match", combined)
        @test occursin("help setup", combined)
        @test !occursin("--help", combined)
        @test !occursin("do not authorize", combined)
    end
    let (code, out, err) = _setup_capture(["--prune", "child:host1"])
        @test code == 0
        @test occursin("Type 'prune' to confirm", out)
        @test occursin("Cancelled.", out)
        @test !occursin("SSH preflight", out * err)
    end
end
