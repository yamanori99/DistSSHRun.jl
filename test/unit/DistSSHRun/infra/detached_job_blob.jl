using DistSSHRun
using Test

@testset "detached job blob round trip" begin
    mktempdir() do d
        run_dir = joinpath(d, "run")
        mkpath(run_dir)
        path = DistSSHRun.write_detached_job_blob!(
            run_dir,
            :drive,
            "job.jl",
            ["parent:2"],
            ["8"],
            d;
            quiet = true,
        )
        @test isfile(path)
        blob = DistSSHRun.read_detached_job_blob(path)
        @test blob.kind === :drive
        @test blob.script == "job.jl"
        @test blob.tokens == ["parent:2"]
    end
end

@testset "detached job blob unknown schema" begin
    mktempdir() do d
        p = joinpath(d, "job.toml")
        write(p, "schema = 99\nkind = \"drive\"\nscript = \"a.jl\"\ntokens = []\nscript_args = []\nproject = \"/tmp\"\n")
        @test_throws ArgumentError DistSSHRun.read_detached_job_blob(p)
    end
end

@testset "drive parsed from job blob" begin
    mktempdir() do d
        run_dir = joinpath(d, "run")
        path = DistSSHRun.write_detached_job_blob!(
            run_dir,
            :drive,
            "job.jl",
            ["parent:2"],
            String[],
            d,
        )
        parsed = DistSSHRun.drive_parsed_from_detached_job_blob(
            DistSSHRun.read_detached_job_blob(path),
        )
        @test parsed.script_path == "job.jl"
        @test parsed.parent_workers == 2
    end
end
