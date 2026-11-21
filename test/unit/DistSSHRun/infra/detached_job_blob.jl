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
        for (extra, needle) in (
                ("require_all_hosts = true\n", "require_all_hosts"),
                ("require_all_hosts = false\n", "best_effort = true"),
                ("collect_best_effort = true\n", "collect_best_effort"),
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
            @test occursin("best_effort", msg)
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
