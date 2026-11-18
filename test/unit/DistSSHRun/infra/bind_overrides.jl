using Test
using DistSSHRun

@testset "launch bind overrides" begin
    @testset "API/CLI parity from TOML hosts file" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts.toml")
            write(
                path,
                """
                [[hosts]]
                name = "lab-a"

                [[hosts]]
                name = "lab-b"
                bind = "10.0.0.2"
                user = "alice"
                """,
            )
            cli = DistSSHRun.CliSharedFlags(hosts_file = path, hint_surface = :cli)
            from_cli = DistSSHRun.hosts_file_bind_overrides(cli)
            from_api = DistSSHRun.resolve_launch_bind_overrides(;
                hosts_file = path,
                surface = :api,
            )
            @test from_cli == from_api
            @test from_api == Dict("alice@lab-b" => "10.0.0.2")
        end
    end

    @testset "DistSSHSession hosts_file" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts.toml")
            write(
                path,
                """
                [[hosts]]
                name = "worker"
                bind = "192.168.1.10"
                """,
            )
            session = DistSSHRun.DistSSHSession(; project = tmp, hosts_file = path)
            overrides = DistSSHRun.hosts_file_bind_overrides(session.cli_session)
            @test overrides == Dict("worker" => "192.168.1.10")
        end
    end

    @testset "bind_overrides= conflicts with hosts file" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts.toml")
            write(
                path,
                """
                [[hosts]]
                name = "h1"
                bind = "10.0.0.1"
                """,
            )
            @test_throws ArgumentError DistSSHRun.resolve_launch_bind_overrides(;
                hosts_file = path,
                bind_overrides = Dict("h1" => "10.0.0.2"),
            )
            let msg = try
                    DistSSHRun.resolve_launch_bind_overrides(;
                        hosts_file = path,
                        bind_overrides = Dict("h1" => "10.0.0.2"),
                    )
                catch e
                    sprint(showerror, e)
                end
                @test occursin("conflicts", msg)
                @test occursin("Hint:", msg)
            end
            @test DistSSHRun.resolve_launch_bind_overrides(;
                hosts_file = path,
                bind_overrides = Dict("h1" => "10.0.0.1"),
            ) == Dict("h1" => "10.0.0.1")
        end
    end

    @testset "machine file rejects bind-like lines" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "machines")
            write(path, "1*lab bind=10.0.0.1\n")
            @test_throws ArgumentError DistSSHRun.read_machine_file_lines(path)
            let err = try
                    DistSSHRun.read_machine_file_lines(path)
                catch e
                    e
                end
                msg = sprint(showerror, err)
                @test occursin("TOML hosts file", msg)
            end
        end
    end

    @testset "bind whitespace not stripped before validation" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts.toml")
            write(
                path,
                """
                [[hosts]]
                name = "h1"
                bind = " 127.0.0.1"
                """,
            )
            let msg = try
                    DistSSHRun.resolve_launch_bind_overrides(;
                        hosts_file = path,
                        planned_hosts = ["h1"],
                    )
                catch e
                    e isa ArgumentError ? e.msg : rethrow()
                end
                @test occursin("whitespace", msg)
            end
            @test_throws ArgumentError DistSSHRun.resolve_launch_bind_overrides(;
                bind_overrides = Dict("h1" => " 10.0.0.1"),
                planned_hosts = ["h1"],
            )
        end
    end

    @testset "go API workers plus hosts_file slots" begin
        _with_tempdir() do tmp
            hf = joinpath(tmp, "hosts.toml")
            write(
                hf,
                """
                [[hosts]]
                name = "lab-b"
                """,
            )
            tokens = String["1*lab-a"]
            resolved = DistSSHRun.merge_go_hosts_file_worker_tokens!(
                tokens, hf;
                hosts_file_tokens_merged = false,
                surface = :api,
            )
            @test resolved == hf
            @test tokens == String["1*lab-a", "lab-b"]
            cli_tokens = String["1*lab-a"]
            DistSSHRun.merge_go_hosts_file_worker_tokens!(
                cli_tokens, hf;
                hosts_file_tokens_merged = true,
                surface = :cli,
            )
            @test cli_tokens == String["1*lab-a"]
            slots = DistSSHRun._go_plan_slots(tokens)
            @test length(slots) == 2
        end
    end

    @testset "drive_parsed_from_session carries bind map" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts.toml")
            write(
                path,
                """
                [[hosts]]
                name = "remote"
                bind = "10.0.0.5"
                """,
            )
            session = DistSSHRun.DistSSHSession(;
                project = tmp,
                workers = String[],
                hosts_file = path,
            )
            script = joinpath(tmp, "job.jl")
            write(script, "function main() end")
            parsed = DistSSHRun.drive_parsed_from_session(session, script)
            merged = DistSSHRun.hosts_file_bind_overrides(
                parsed.cli_session;
                bind_overrides = parsed.bind_overrides,
            )
            @test merged == Dict("remote" => "10.0.0.5")
        end
    end
end
