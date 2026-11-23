using DistSSHRun
using Test

function _job_blob_minimal_toml()::String
    return """
    writer = \"$(DistSSHRun.run_record_writer())\"
    kind = "drive"
    script = "a.jl"
    tokens = []
    script_args = []
    project = "/tmp/p"
    """
end

@testset "detached job blob round trip" begin
    mktempdir() do d
        run_dir = joinpath(d, "run")
        mkpath(run_dir)
        path = DistSSHRun.write_detached_job_blob!(
            run_dir,
            :drive,
            "job.jl",
            ["2*host1"],
            ["8"],
            d;
            quiet = true,
            head_workers = 2,
            best_effort = true,
        )
        @test isfile(path)
        blob = DistSSHRun.read_detached_job_blob(path)
        @test blob.kind === :drive
        @test blob.script == "job.jl"
        @test blob.tokens == ["2*host1"]
        @test blob.head_workers == 2
        @test blob.best_effort
    end
end

@testset "detached job blob writer mismatch" begin
    mktempdir() do d
        p = joinpath(d, "job.toml")
        write(
            p,
            "writer = \"DistSSHRun 0.1.0\"\nkind = \"drive\"\nscript = \"a.jl\"\ntokens = []\nscript_args = []\nproject = \"/tmp\"\n",
        )
        @test_throws ArgumentError DistSSHRun.read_detached_job_blob(p)
    end
end

@testset "detached job blob rejects legacy join keys" begin
    mktempdir() do d
        p = joinpath(d, "job.toml")
        for (extra, needle, hint) in (
                ("require_all_hosts = true\n", "require_all_hosts", "best_effort"),
                ("require_all_hosts = false\n", "best_effort = true", "best_effort"),
                ("collect_best_effort = true\n", "collect_best_effort", "best_effort"),
                ("run_id = \"20260101T000000Z-aaaaaa\"\n", "run_id", "ship_id"),
            )
            write(p, _job_blob_minimal_toml() * extra)
            err = try
                DistSSHRun.read_detached_job_blob(p)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            msg = sprint(showerror, err)
            @test occursin(needle, msg)
            @test occursin(hint, msg)
            @test occursin("Rewrite", msg)
        end
    end
end

@testset "drive parsed from job blob" begin
    mktempdir() do d
        run_dir = joinpath(d, "run")
        path = DistSSHRun.write_detached_job_blob!(
            run_dir,
            :drive,
            "job.jl",
            String[],
            String[],
            d;
            head_workers = 2,
        )
        parsed = DistSSHRun.drive_parsed_from_detached_job_blob(
            DistSSHRun.read_detached_job_blob(path),
        )
        @test parsed.script_path == "job.jl"
        @test parsed.head_workers == 2
        @test !parsed.best_effort
    end
end

function _detached_blob_path(d::AbstractString, kind::Symbol)::String
    run_dir = joinpath(d, "run")
    mkpath(run_dir)
    return DistSSHRun.write_detached_job_blob!(
        run_dir,
        kind,
        "job.jl",
        kind === :drive ? ["1*h1"] : ["1*h1"],
        String[],
        d;
        head_workers = kind === :drive ? 1 : nothing,
        head_slots = kind === :go ? 1 : nothing,
    )
end

@testset "detached job blob bootstrap argv" begin
    mktempdir() do d
        path = _detached_blob_path(d, :drive)
        bootstrap = String["-y", "--job-blob", path]
        @test isfile(path)
        @test DistSSHRun.parse_drive_args(bootstrap).script_path == "job.jl"
        @test_throws ArgumentError DistSSHRun.parse_drive_args(
            [bootstrap..., "--best-effort"],
        )
        @test_throws ArgumentError DistSSHRun.parse_drive_args(
            String["--job-blob", path, "--quiet"],
        )
        go_path = _detached_blob_path(d, :go)
        go_bootstrap = String["-y", "--job-blob", go_path]
        @test_throws ArgumentError DistSSHRun.parse_go_args([go_bootstrap..., "1*h1"])
        @test DistSSHRun.parse_go_args(go_bootstrap).script_path == "job.jl"
    end
end

@testset "detached job blob captures parent env into blob" begin
    mktempdir() do d
        run_dir = joinpath(d, "run")
        path = withenv(
            "DISTSSH_UNSAFE_MASTER_SILENCE_EXIT" => "1",
            "DISTSSH_HEARTBEAT_DEADLINE_SEC" => "9",
            "DISTSSH_HEARTBEAT_INTERVAL_SEC" => "2",
            "DISTSSH_TOPOLOGY" => "master_worker",
        ) do
            fields = DistSSHRun.detached_job_blob_fields_from_env()
            @test fields[:unsafe_master_silence_exit]
            @test fields[:topology] == "master_worker"
            @test fields[:distributed_heartbeat_deadline_sec] == 9.0
            @test fields[:distributed_heartbeat_interval_sec] == 2.0
            blob_path = DistSSHRun.write_detached_job_blob!(
                run_dir,
                :drive,
                "job.jl",
                ["1*h1"],
                String[],
                d;
                head_workers = 1,
                unsafe_master_silence_exit = fields[:unsafe_master_silence_exit],
                distributed_heartbeat_deadline_sec = fields[:distributed_heartbeat_deadline_sec],
                distributed_heartbeat_interval_sec = fields[:distributed_heartbeat_interval_sec],
                topology = fields[:topology],
            )
            blob = DistSSHRun.read_detached_job_blob(blob_path)
            @test blob.unsafe_master_silence_exit
            @test blob.topology == "master_worker"
            @test blob.distributed_heartbeat_deadline_sec == 9.0
            return blob_path
        end
        withenv(
            "DISTSSH_UNSAFE_MASTER_SILENCE_EXIT" => "1",
            "DISTSSH_HEARTBEAT_DEADLINE_SEC" => "5",
        ) do
            parsed = DistSSHRun.parse_drive_args(String["-y", "--job-blob", path])
            pol = DistSSHRun.resolve_drive_heartbeat_policy(
                env = parsed.cli_session.process_env,
                self_exit = parsed.unsafe_master_silence_exit,
            )
            @test pol.self_exit
            @test pol.deadline == 9.0
        end
    end
end

@testset "detached job blob ignores job-default env" begin
    mktempdir() do d
        path = _detached_blob_path(d, :drive)
        let topology = "master_worker"
            withenv(Dict("DISTSSH_TOPOLOGY" => topology)...) do
                parsed = DistSSHRun.parse_drive_args(String["-y", "--job-blob", path])
                cfg = DistSSHRun.resolve_run_job_config_from_parsed(parsed; command = :drive)
                @test cfg.topology.value == "auto"
                @test cfg.topology.source == DistSSHRun.FromDefault
            end
        end
    end
    mktempdir() do d
        path = _detached_blob_path(d, :go)
        withenv(
            "DISTSSH_TOPOLOGY" => "master_worker",
            "DISTSSH_UNSAFE_EXPOSE_PORT" => "1",
        ) do
            parsed = DistSSHRun.parse_go_args(String["-y", "--job-blob", path])
            cfg = DistSSHRun.resolve_run_job_config_from_parsed(parsed; command = :go)
            @test cfg.topology.value == "auto"
            @test !cfg.unsafe_expose_port.value
        end
    end
end
