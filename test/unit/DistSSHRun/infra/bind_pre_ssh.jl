using Test
using DistSSHRun
using DistSSHRun.DistSSHBase: CliUsageError, CLI_EXIT_USAGE, with_cli_exit

if !isdefined(Main, :TEST_PROJECT)
    Core.eval(Main, :(const TEST_PROJECT = $(abspath(joinpath(@__DIR__, "..", "..", "..")))))
end

@testset "bind config is enforced before PATH ssh" begin
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

    function _drive_bind_reject_session(tmp::AbstractString, hosts_path::AbstractString, best_effort::Bool)
        proj = joinpath(tmp, "proj")
        mkpath(proj)
        write(joinpath(proj, "Project.toml"), "name = \"BindPreSsh\"\n")
        _sync_test_project_manifest!(proj)
        script = joinpath(proj, "job.jl")
        # No `function main`. `integration/drive/api.jl` is the first in-process
        # driver include with `main` and asserts stderr has no warn-overwrite.
        write(script, "# driver include only\n")
        session = DistSSHRun.DistSSHSession(
            project = proj,
            workers = String[],
            hosts_file = hosts_path,
            quiet = true,
            verbosity = :quiet,
        )
        session.cli_session.hint_surface = :cli
        parsed = DistSSHRun.drive_parsed_from_session(
            session,
            script;
            workers = DistSSHRun.WorkerPlan(0, Dict("reject-ssh.test" => 1)),
            enable_log = false,
            skip_hash_check = true,
            best_effort = best_effort,
            julia = joinpath(Sys.BINDIR, Base.julia_exename()),
        )
        return parsed, proj
    end

    @testset "exit 2 and recording ssh never runs" begin
        _with_tempdir() do tmp
            hosts_path = joinpath(tmp, "hosts.toml")
            write(
                hosts_path,
                """
                [[hosts]]
                name = "reject-ssh.test"
                bind = "localhost"
                """,
            )
            bindir, logp = _recording_ssh_bin(tmp)
            parsed, proj = _drive_bind_reject_session(tmp, hosts_path, false)
            path = bindir * ":" * get(ENV, "PATH", "")
            code = withenv(
                "PATH" => path,
                "DISTSSH_SKIP_GLOBAL_WORKER_PKILL" => "1",
            ) do
                redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        with_cli_exit() do
                            try
                                return DistSSHRun.run_drive_parsed!(parsed; project_root = proj)
                            catch e
                                e isa CliUsageError && rethrow()
                                rethrow()
                            end
                        end
                    end
                end
            end
            @test code == CLI_EXIT_USAGE
            @test !isfile(logp) || read(logp, String) == ""
        end
    end

    @testset "same under --best-effort" begin
        _with_tempdir() do tmp
            hosts_path = joinpath(tmp, "hosts.toml")
            write(
                hosts_path,
                """
                [[hosts]]
                name = "reject-ssh.test"
                bind = "localhost"
                """,
            )
            bindir, logp = _recording_ssh_bin(tmp)
            parsed, proj = _drive_bind_reject_session(tmp, hosts_path, true)
            path = bindir * ":" * get(ENV, "PATH", "")
            code = withenv(
                "PATH" => path,
                "DISTSSH_SKIP_GLOBAL_WORKER_PKILL" => "1",
            ) do
                redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        with_cli_exit() do
                            try
                                return DistSSHRun.run_drive_parsed!(parsed; project_root = proj)
                            catch e
                                e isa CliUsageError && rethrow()
                                rethrow()
                            end
                        end
                    end
                end
            end
            @test code == CLI_EXIT_USAGE
            @test !isfile(logp) || read(logp, String) == ""
        end
    end

    @testset "drive and go kit CLI exit 2 on bad bind" begin
        _with_tempdir() do tmp
            hosts_path = joinpath(tmp, "hosts.toml")
            write(
                hosts_path,
                """
                [[hosts]]
                name = "reject-ssh.test"
                workers = 1
                bind = "localhost"
                """,
            )
            proj = joinpath(tmp, "proj")
            mkpath(proj)
            write(joinpath(proj, "Project.toml"), "name = \"BindCli\"\n")
            _sync_test_project_manifest!(proj)
            script = joinpath(proj, "job.jl")
            write(
                script,
                """
                using Distributed
                pmap(identity, 1:2)
                """,
            )
            bindir, logp = _recording_ssh_bin(tmp)
            path = bindir * ":" * get(ENV, "PATH", "")
            env = Dict(
                "PATH" => path,
                "DISTSSH_SKIP_GLOBAL_WORKER_PKILL" => "1",
                "DISTSSH_QUIET" => "1",
            )
            for cmd_args in (
                    String[
                        "drive", "-y", "--hosts-file", hosts_path, "--head-workers", "0",
                        "1*reject-ssh.test", script,
                    ],
                    String["go", "-y", "--hosts-file", hosts_path, script],
                )
                proc, _ = _run_subprocess(setenv(_kit_cli_cmd(cmd_args; project = _kit_root()), env))
                @test proc.exitcode == Int(CLI_EXIT_USAGE)
            end
            @test !isfile(logp) || read(logp, String) == ""
        end
    end
end
