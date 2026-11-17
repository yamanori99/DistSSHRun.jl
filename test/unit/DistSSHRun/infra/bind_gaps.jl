using Test
using DistSSHRun
using DistSSHRun.DistSSHBase: read_toml_host_entries

@testset "bind contract regressions (#503 gaps)" begin
    @testset "gap 1 ride dry-run uses ssh dest for bind lookup" begin
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
                command = :ride,
                cli_dry_run = true,
                cli_unsafe_expose_port = true,
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
                    command = :ride,
                ),
            )
            txt = String(take!(buf))
            @test occursin("bind=192.0.2.2", txt)
            @test !occursin("bind=127.0.0.1", txt)
        end
    end

    @testset "gap 2 ride unsafe_expose_port env when CLI omits flag" begin
        let old = get(ENV, "DISTSSH_UNSAFE_EXPOSE_PORT", nothing)
            try
                ENV["DISTSSH_UNSAFE_EXPOSE_PORT"] = "1"
                parsed = DistSSHRun.parse_ride_args(String["1*host", "script.jl"])
                cfg = DistSSHRun.resolve_run_job_config_from_parsed(parsed; command = :ride)
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

    @testset "gap 7 go rejects bind settings" begin
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
            @test_throws ArgumentError DistSSHRun.resolve_launch_bind_overrides(;
                hosts_file = path,
                planned_hosts = ["h1"],
                command = :go,
            )
        end
    end
end
