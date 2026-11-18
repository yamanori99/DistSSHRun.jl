using Test
using DistSSHRun
using DistSSHRun.DistSSHBase: CliUsageError, CLI_EXIT_USAGE, with_cli_exit

if !isdefined(Main, :TEST_PROJECT)
    Core.eval(Main, :(const TEST_PROJECT = $(abspath(joinpath(@__DIR__, "..", "..", "..")))))
end

@testset "ride and go CLI bind paths" begin
    function _recording_ssh_bin(tmp::AbstractString)
        bindir = joinpath(tmp, "bin")
        logp = joinpath(tmp, "ssh.log")
        mkpath(bindir)
        logq = replace(logp, "'" => "'\\''")
        ssh_bin = joinpath(bindir, "ssh")
        write(
            ssh_bin,
            """
            #!/bin/sh
            echo "\$0 \$@" >> '$logq'
            exit 99
            """,
        )
        chmod(ssh_bin, 0o755)
        return bindir, logp
    end

    function _minimal_proj(tmp::AbstractString)
        proj = joinpath(tmp, "proj")
        mkpath(proj)
        write(joinpath(proj, "Project.toml"), "name = \"CliBindEntry\"\n")
        _sync_test_project_manifest!(proj)
        script = joinpath(proj, "job.jl")
        write(script, "map(identity, 1:2)\n")
        return proj, script
    end

    @testset "ride_main default launch reaches ssh" begin
        _with_tempdir() do tmp
            proj, script = _minimal_proj(tmp)
            bindir, logp = _recording_ssh_bin(tmp)
            path = bindir * ":" * get(ENV, "PATH", "")
            include(joinpath(@__DIR__, "..", "..", "..", "src", "cli", "ride.jl"))
            code = withenv(
                "PATH" => path,
                "DISTSSH_SKIP_GLOBAL_WORKER_PKILL" => "1",
                "DIST_SSH_KIT_CLI_INCLUDE" => "1",
            ) do
                cd(proj) do
                    empty!(ARGS)
                    append!(ARGS, ["-y", "--no-spi-check", "1*alice@mac-b", basename(script)])
                    return redirect_stdout(devnull) do
                        redirect_stderr(devnull) do
                            with_cli_exit() do
                                return ride_main()
                            end
                        end
                    end
                end
            end
            @test code != CLI_EXIT_USAGE
            if isfile(logp)
                @test !isempty(strip(read(logp, String)))
            end
        end
    end

    @testset "go_main default launch (no Missing TypeError)" begin
        _with_tempdir() do tmp
            proj, script = _minimal_proj(tmp)
            bindir, logp = _recording_ssh_bin(tmp)
            path = bindir * ":" * get(ENV, "PATH", "")
            include(joinpath(@__DIR__, "..", "..", "..", "src", "cli", "go.jl"))
            code = withenv(
                "PATH" => path,
                "DISTSSH_SKIP_GLOBAL_WORKER_PKILL" => "1",
                "DIST_SSH_KIT_CLI_INCLUDE" => "1",
            ) do
                cd(proj) do
                    empty!(ARGS)
                    append!(ARGS, ["-y", "1*alice@mac-b", basename(script)])
                    return redirect_stdout(devnull) do
                        redirect_stderr(devnull) do
                            with_cli_exit() do
                                return go_main()
                            end
                        end
                    end
                end
            end
            @test code != CLI_EXIT_USAGE
        end
    end

    @testset "ride --unsafe-expose-port respects launch plan" begin
        _with_tempdir() do tmp
            hosts_path = joinpath(tmp, "hosts.toml")
            write(
                hosts_path,
                """
                [[hosts]]
                name = "alice@mac-b"
                bind = "10.0.0.2"
                """,
            )
            _minimal_proj(tmp)
            parsed = DistSSHRun.parse_ride_args(
                String[
                    "--unsafe-expose-port",
                    "--hosts-file",
                    hosts_path,
                    joinpath(tmp, "proj", "job.jl"),
                ],
            )
            cfg = DistSSHRun.resolve_run_job_config_from_parsed(parsed; command = :ride)
            @test cfg.unsafe_expose_port.value
            overrides = DistSSHRun.hosts_file_bind_overrides(
                parsed.cli_session;
                planned_hosts = ["alice@mac-b"],
                command = :ride,
            )
            plan = DistSSHRun.validate_host_launch_plan(
                "1*alice@mac-b",
                DistSSHRun.resolved_bind_address("alice@mac-b", overrides);
                unsafe_expose_port = cfg.unsafe_expose_port.value,
            )
            @test plan.bind == "10.0.0.2"
        end
    end
end