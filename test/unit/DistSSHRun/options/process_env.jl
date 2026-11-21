using Test
using DistSSHRun

@testset "process env snapshot" begin
    @testset "parser reads frozen copy not live ENV" begin
        withenv(
            "DISTSSH_YES" => "",
            "DISTSSH_HOSTS" => "ignored",
            "JULIA_DISTRIBUTED_EXE" => "/live/julia",
        ) do
            pe = DistSSHRun.ProcessEnv(Dict(
                "DISTSSH_YES" => "1",
                "JULIA_DISTRIBUTED_EXE" => "/frozen/julia",
            ))
            parsed = DistSSHRun.parse_setup_args(String["check", "host1"]; env = pe)
            @test parsed.cli_session.yes
            @test parsed.julia_path == "/frozen/julia"
            pe_hosts = DistSSHRun.ProcessEnv(Dict("DISTSSH_HOSTS" => "2*frozen"))
            session = DistSSHRun.default_kit_cli_session(pe_hosts)
            @test DistSSHRun.placement_source_tokens(session; keep_counts = true) ==
                String["2*frozen"]
        end
    end

    @testset "option resolve ignores later ENV mutations" begin
        pe = DistSSHRun.ProcessEnv(Dict("DISTSSH_UNSAFE_SKIP_ENV_DIGESTS" => "1"))
        cfg = DistSSHRun.resolve_run_job_config(; command = :go, env = pe)
        @test cfg.unsafe_skip_env_digests.value
        @test cfg.unsafe_skip_env_digests.source == DistSSHRun.FromEnv
        ENV["DISTSSH_UNSAFE_SKIP_ENV_DIGESTS"] = "0"
        try
            cfg2 = DistSSHRun.resolve_run_job_config(; command = :go, env = pe)
            @test cfg2.unsafe_skip_env_digests.value
        finally
            delete!(ENV, "DISTSSH_UNSAFE_SKIP_ENV_DIGESTS")
        end
    end

    @testset "removed join env keys fail on snapshot" begin
        pe = DistSSHRun.ProcessEnv(Dict("DISTSSH_REQUIRE_ALL_HOSTS" => "1"))
        @test_throws ArgumentError DistSSHRun.parse_drive_args(["script.jl"]; env = pe)
    end

    @testset "cli_session shares env with resolve_run_job_config_from_parsed" begin
        pe = DistSSHRun.ProcessEnv(Dict("DISTSSH_UNSAFE_EXPOSE_PORT" => "1"))
        parsed = DistSSHRun.parse_drive_args(String["1*host1", "x.jl"]; env = pe)
        cfg = DistSSHRun.resolve_run_job_config_from_parsed(parsed; command = :drive)
        @test cfg.unsafe_expose_port.value
        @test parsed.cli_session.process_env === pe
    end
end