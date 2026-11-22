using Test
using DistSSHRun
using DistSSHRun.DistSSHBase: CliUsageError, CLI_EXIT_USAGE, with_cli_exit

# Fixture path must not use Main.TEST_PROJECT: runtests.jl sets that to
# Base.active_project() (the Project.toml path), not the repo root.
const _CLI_BIND_FAKE_SSH =
    abspath(joinpath(@__DIR__, "..", "..", "..", "test", "fixtures", "fake_snapshot_ssh.jl"))

@testset "drive and go CLI bind paths" begin

    function _recording_ssh_bin(tmp::AbstractString)
        bindir = joinpath(tmp, "bin")
        logp = joinpath(tmp, "ssh.log")
        mkpath(bindir)
        logq = replace(logp, "'" => "'\\''")
        stub = """
        #!/bin/sh
        echo "\$0 \$@" >> '$logq'
        exit 99
        """
        for name in ("ssh", "scp")
            tool = joinpath(bindir, name)
            write(tool, stub)
            chmod(tool, 0o755)
        end
        return bindir, logp
    end

    function _minimal_proj(tmp::AbstractString)
        proj = joinpath(tmp, "proj")
        mkpath(proj)
        _write_test_job_with_distsshrun!(proj; name = "CliBindEntry")
        script = joinpath(proj, "job.jl")
        write(
            script,
            """
            using Distributed
            pmap(identity, 1:2)
            """,
        )
        hosts_path = joinpath(tmp, "hosts.toml")
        write(
            hosts_path,
            """
            [[hosts]]
            name = "mac-b"
            workers = 1
            user = "alice"
            bind = "127.0.0.1"
            """,
        )
        return proj, script, hosts_path
    end

    function _cli_bind_test_env(
            path::AbstractString,
            logp::AbstractString,
            proj::AbstractString,
        )::Dict{String, String}
        return Dict{String, String}(
            "PATH" => path,
            "DISTSSH_SKIP_GLOBAL_WORKER_PKILL" => "1",
            "DIST_SSH_KIT_CLI_INCLUDE" => "1",
            "DISTSSH_TEST" => "1",
            "DISTSSH_TEST_SSH" => _CLI_BIND_FAKE_SSH,
            "DISTSSH_TEST_SSH_LOG" => logp,
            "DISTSSH_TEST_POSIX_SHELL" => "1",
            "DISTRIBUTED_PROJECT_ROOT" => DistSSHRun.canonical_local_path(proj),
        )
    end

    function _with_cli_bind_env(env::Dict{String, String}, f::Function)
        return withenv(env...) do
            delete!(ENV, DistSSHRun.DISTSSH_RUN_DIR_ENV)
            DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
            return f()
        end
    end

    @testset "drive_main default launch reaches ssh" begin
        # An earlier in-process drive! in this process must not block CLI drive.
        DistSSHRun._set_drive_main_driver_included!()
        _with_tempdir() do tmp
            proj, script, hosts_path = _minimal_proj(tmp)
            bindir, logp = _recording_ssh_bin(tmp)
            path = bindir * ":" * get(ENV, "PATH", "")
            include(joinpath(@__DIR__, "..", "..", "..", "src", "cli", "drive.jl"))
            env = _cli_bind_test_env(path, logp, proj)
            code = _with_cli_bind_env(
                env, () ->
                cd(proj) do
                    empty!(ARGS)
                    append!(
                        ARGS,
                        String["-y", "--hosts-file", hosts_path, basename(script)],
                    )
                    return redirect_stdout(devnull) do
                        redirect_stderr(devnull) do
                            with_cli_exit() do
                                return Base.invokelatest(drive_main)
                            end
                        end
                    end
                end
            )
            @test isfile(logp)
            @test occursin("HOST ", read(logp, String))
        end
    end

    @testset "go_main default launch (no Missing TypeError)" begin
        _with_tempdir() do tmp
            proj = joinpath(tmp, "proj")
            mkpath(proj)
            _write_test_job_with_distsshrun!(proj; name = "CliBindEntry")
            script = joinpath(proj, "job.jl")
            write(script, "map(identity, 1:2)\n")
            bindir, logp = _recording_ssh_bin(tmp)
            path = bindir * ":" * get(ENV, "PATH", "")
            include(joinpath(@__DIR__, "..", "..", "..", "src", "cli", "go.jl"))
            env = _cli_bind_test_env(path, logp, proj)
            _with_cli_bind_env(
                env, () ->
                cd(proj) do
                    empty!(ARGS)
                    append!(ARGS, String["-y", "1*alice@mac-b", basename(script)])
                    return redirect_stdout(devnull) do
                        redirect_stderr(devnull) do
                            with_cli_exit() do
                                return Base.invokelatest(go_main)
                            end
                        end
                    end
                end
            )
            @test isfile(logp)
            @test occursin("HOST ", read(logp, String))
        end
    end

    @testset "drive --unsafe-expose-port respects launch plan" begin
        _with_tempdir() do tmp
            _, _, hosts_path = _minimal_proj(tmp)
            write(
                hosts_path,
                """
                [[hosts]]
                name = "alice@mac-b"
                bind = "10.0.0.2"
                """,
            )
            parsed = DistSSHRun.parse_drive_args(
                String[
                    "--unsafe-expose-port",
                    "--hosts-file",
                    hosts_path,
                    joinpath(tmp, "proj", "job.jl"),
                ],
            )
            cfg = DistSSHRun.resolve_run_job_config_from_parsed(parsed; command = :drive)
            @test cfg.unsafe_expose_port.value
            overrides = DistSSHRun.hosts_file_bind_overrides(
                parsed.cli_session;
                planned_hosts = ["alice@mac-b"],
                command = :drive,
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
