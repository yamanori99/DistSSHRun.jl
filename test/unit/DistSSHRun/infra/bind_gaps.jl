using Test
using DistSSHRun
using DistSSHRun.DistSSHBase: CliUsageError, read_toml_host_entries

@testset "bind contract regressions (#503 gaps)" begin
    @testset "gap 1 drive dry-run uses ssh dest for bind lookup" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts.toml")
            write(
                path,
                """
                [[hosts]]
                name = "mac-b"
                workers = 2
                user = "alice"
                bind = "192.0.2.2"
                """,
            )
            cli = DistSSHRun.CliSharedFlags(hosts_file = path, hint_surface = :cli)
            cfg = DistSSHRun.resolve_run_job_config(;
                command = :drive,
                cli_dry_run = true,
                cli_unsafe_expose_port = true,
                env = cli.process_env,
            )
            buf = IOBuffer()
            DistSSHRun.print_run_job_dry_plan!(
                buf,
                cfg;
                hosts = ["2*alice@mac-b"],
                worker_tokens = ["2*alice@mac-b"],
                project = tmp,
                head_workers = 0,
                bind_overrides = DistSSHRun.hosts_file_bind_overrides(
                    cli;
                    planned_hosts = ["alice@mac-b"],
                    command = :drive,
                ),
            )
            txt = String(take!(buf))
            @test occursin("bind=192.0.2.2", txt)
            @test !occursin("bind=127.0.0.1", txt)
        end
    end

    @testset "gap 1b drive dry-run non-loopback bind exits usage" begin
        _with_tempdir() do tmp
            proj = joinpath(tmp, "proj")
            mkpath(proj)
            write(joinpath(proj, "Project.toml"), "name = \"DryBind\"\n")
            _sync_test_project_manifest!(proj)
            script = joinpath(proj, "job.jl")
            write(
                script,
                """
                using Distributed
                pmap(identity, 1:2)
                """,
            )
            hf = joinpath(tmp, "hosts.toml")
            write(
                hf,
                """
                [[hosts]]
                name = "lab"
                workers = 1
                bind = "10.0.0.5"
                """,
            )
            parsed = DistSSHRun.parse_drive_args(
                String["--dry-run", "--hosts-file", hf, basename(script)],
            )
            err = try
                DistSSHRun.finish_run_job_diagnostics!(
                    parsed;
                    command = :drive,
                    project = proj,
                    hosts = String[first(h) for h in parsed.hosts],
                    worker_tokens = DistSSHRun.host_tokens(parsed; kind = :drive),
                )
            catch e
                e
            end
            @test err isa CliUsageError
            @test occursin("non-loopback", err.msg)
        end
    end

    @testset "gap 3 string loopback bypass rejected" begin
        msg = try
            DistSSHRun.parse_bind_ipv4_literal("127.evil.example")
        catch e
            e isa ArgumentError ? e.msg : rethrow()
        end
        @test msg ==
            "bind \"127.evil.example\" is not an IPv4 address; checked: dotted-quad IPv4 literal (names are not resolved); fix: bind = \"127.0.0.1\""
        @test_throws ArgumentError DistSSHRun.parse_bind_ipv4_literal("localhost")
    end

    @testset "gap 4 bind config not demoted by best_effort (exit 2)" begin
        msg = try
            DistSSHRun.validate_all_host_launch_plans!(["h1"], Dict("h1" => "192.0.2.2"))
        catch e
            e isa ArgumentError ? e.msg : rethrow()
        end
        @test occursin("non-loopback bind", msg)
    end

    @testset "gap 2 drive unsafe_expose_port env when CLI omits flag" begin
        let old = get(ENV, "DISTSSH_UNSAFE_EXPOSE_PORT", nothing)
            try
                ENV["DISTSSH_UNSAFE_EXPOSE_PORT"] = "1"
                parsed = DistSSHRun.parse_drive_args(String["1*host", "script.jl"])
                cfg = DistSSHRun.resolve_run_job_config_from_parsed(parsed; command = :drive)
                @test cfg.unsafe_expose_port.value
                @test cfg.unsafe_expose_port.source == DistSSHRun.FromEnv
            finally
                old === nothing ? delete!(ENV, "DISTSSH_UNSAFE_EXPOSE_PORT") :
                    (ENV["DISTSSH_UNSAFE_EXPOSE_PORT"] = old)
            end
        end
    end

    @testset "gap 5 non-string TOML bind" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts.toml")
            write(
                path,
                """
                [[hosts]]
                name = "h1"
                bind = 1
                """,
            )
            @test_throws ArgumentError read_toml_host_entries(path)
            let msg = try
                    read_toml_host_entries(path)
                catch e
                    e isa ArgumentError ? e.msg : rethrow()
                end
                @test occursin("bind must be a string", msg)
                @test occursin("Int64", msg)
            end
        end
    end

    @testset "gap 6 bind_overrides unknown host and drive env unsafe" begin
        @test_throws ArgumentError DistSSHRun.resolve_launch_bind_overrides(;
            bind_overrides = Dict("ghost" => "10.0.0.1"),
            planned_hosts = String[],
        )
        @test_throws ArgumentError DistSSHRun.resolve_launch_bind_overrides(;
            bind_overrides = Dict("ghost" => "10.0.0.1"),
            planned_hosts = ["alice@lab"],
        )
        let msg = try
                DistSSHRun.resolve_launch_bind_overrides(;
                    bind_overrides = Dict("ghost" => "10.0.0.1"),
                    planned_hosts = ["alice@lab"],
                )
            catch e
                e isa ArgumentError ? e.msg : rethrow()
            end
            @test occursin("ghost", msg)
            @test occursin("alice@lab", msg)
        end
        _with_tempdir() do tmp
            session = DistSSHRun.DistSSHSession(project = tmp, workers = String[])
            let old = get(ENV, "DISTSSH_UNSAFE_EXPOSE_PORT", nothing)
                try
                    ENV["DISTSSH_UNSAFE_EXPOSE_PORT"] = "1"
                    parsed = DistSSHRun.drive_parsed_from_session(session, joinpath(tmp, "j.jl"))
                    cfg = DistSSHRun.resolve_run_job_config_from_parsed(parsed; command = :drive)
                    @test cfg.unsafe_expose_port.value
                    @test cfg.unsafe_expose_port.source == DistSSHRun.FromEnv
                finally
                    old === nothing ? delete!(ENV, "DISTSSH_UNSAFE_EXPOSE_PORT") :
                        (ENV["DISTSSH_UNSAFE_EXPOSE_PORT"] = old)
                end
            end
        end
    end

    @testset "gap 7 0.0.0.0 with tunnel off" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts.toml")
            write(
                path,
                """
                [[hosts]]
                name = "h1"
                bind = "0.0.0.0"
                """,
            )
            let msg = try
                    DistSSHRun.validate_host_launch_plan(
                        "h1",
                        "0.0.0.0";
                        tunnel = false,
                        unsafe_expose_port = true,
                    )
                catch e
                    e isa ArgumentError ? e.msg : rethrow()
                end
                @test msg == join(
                    [
                        "\"h1\": bind 0.0.0.0 requires --unsafe-expose-port and SSH tunnel enabled",
                        "Hint: pass --unsafe-expose-port and keep tunnel enabled (default)",
                    ],
                    "\n",
                )
            end
        end
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts.toml")
            write(
                path,
                """
                [[hosts]]
                name = "h1"
                bind = "127.0.0.1"
                """,
            )
            let msg = try
                    DistSSHRun.resolve_launch_bind_overrides(;
                        hosts_file = path,
                        planned_hosts = ["h1"],
                        command = :go,
                    )
                catch e
                    e isa ArgumentError ? e.msg : rethrow()
                end
                @test occursin("go", msg)
                @test occursin("bind is not supported for go", msg)
            end
        end
    end

    @testset "parity cli explicit false vs env for unsafe_expose_port" begin
        let old = get(ENV, "DISTSSH_UNSAFE_EXPOSE_PORT", nothing)
            try
                ENV["DISTSSH_UNSAFE_EXPOSE_PORT"] = "1"
                parsed_cli = DistSSHRun.parse_drive_args(
                    String["--unsafe-expose-port", "1*host", "script.jl"],
                )
                cfg_cli = DistSSHRun.resolve_run_job_config_from_parsed(parsed_cli; command = :drive)
                @test cfg_cli.unsafe_expose_port.value
                @test cfg_cli.unsafe_expose_port.source == DistSSHRun.FromCLI
                parsed = DistSSHRun.parse_drive_args(String["1*host", "script.jl"])
                cfg = DistSSHRun.resolve_run_job_config_from_parsed(parsed; command = :drive)
                @test cfg.unsafe_expose_port.value
                @test cfg.unsafe_expose_port.source == DistSSHRun.FromEnv
                _with_tempdir() do tmp
                    session = DistSSHRun.DistSSHSession(project = tmp, workers = String[])
                    write(joinpath(tmp, "j.jl"), "1\n")
                    parsed_api = DistSSHRun.drive_parsed_from_session(
                        session,
                        joinpath(tmp, "j.jl");
                        unsafe_expose_port = false,
                    )
                    cfg_api = DistSSHRun.resolve_run_job_config_from_parsed(parsed_api; command = :drive)
                    @test !cfg_api.unsafe_expose_port.value
                    @test cfg_api.unsafe_expose_port.source == DistSSHRun.FromCLI
                end
            finally
                old === nothing ? delete!(ENV, "DISTSSH_UNSAFE_EXPOSE_PORT") :
                    (ENV["DISTSSH_UNSAFE_EXPOSE_PORT"] = old)
            end
        end
    end

    @testset "drive! unsafe_expose_port non-loopback gate" begin
        non_loopback_reject = join(
            [
                "\"lab\": non-loopback bind \"10.0.0.5\"",
                "Hint: pass --unsafe-expose-port to expose the worker port beyond loopback",
            ],
            "\n",
        )
        bind = Dict("lab" => "10.0.0.5")
        _with_tempdir() do tmp
            proj = joinpath(tmp, "proj")
            mkpath(proj)
            write(joinpath(proj, "Project.toml"), "name = \"BindGateApi\"\n")
            _sync_test_project_manifest!(proj)
            script = joinpath(proj, "job.jl")
            write(script, "map(identity, 1:2)\n")
            bindir = joinpath(tmp, "bin")
            mkpath(bindir)
            logp = joinpath(tmp, "ssh.log")
            logq = replace(logp, "'" => "'\\''")
            write(
                joinpath(bindir, "ssh"),
                """
                #!/bin/sh
                echo "\$0 \$@" >> '$logq'
                exit 99
                """,
            )
            chmod(joinpath(bindir, "ssh"), 0o755)
            withenv(
                "PATH" => bindir * ":" * get(ENV, "PATH", ""),
                "DISTSSH_SKIP_GLOBAL_WORKER_PKILL" => "1",
            ) do
                session = DistSSHRun.DistSSHSession(
                    project = proj,
                    workers = String[],
                    quiet = true,
                    verbosity = :quiet,
                )
                session.cli_session.hint_surface = :cli
                let err = try
                        DistSSHRun.drive!(
                            session,
                            script;
                            plan = DistSSHRun.WorkerPlan(0, Dict("lab" => 1)),
                            bind_overrides = bind,
                            unsafe_expose_port = nothing,
                            skip_hash_check = true,
                            enable_log = false,
                            reuse_main = true,
                        )
                    catch e
                        e isa CliUsageError ? e : rethrow()
                    end
                    @test err isa CliUsageError
                    @test err.msg == non_loopback_reject
                end
                @test !isfile(logp) || read(logp, String) == ""
                past_gate(f) = try
                    f()
                    true
                catch e
                    (e isa CliUsageError && e.msg == non_loopback_reject) && rethrow()
                    true
                end
                julia_exe = joinpath(Sys.BINDIR, Base.julia_exename())
                @test past_gate() do
                    redirect_stderr(devnull) do
                        DistSSHRun.drive!(
                            session,
                            script;
                            plan = DistSSHRun.WorkerPlan(0, Dict("lab" => 1)),
                            bind_overrides = bind,
                            unsafe_expose_port = true,
                            skip_hash_check = true,
                            enable_log = false,
                            julia = julia_exe,
                            reuse_main = true,
                        )
                    end
                end
            end
        end
    end
end
