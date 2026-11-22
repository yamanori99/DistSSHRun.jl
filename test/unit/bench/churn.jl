using Test
using Dates

include(joinpath(@__DIR__, "..", "..", "..", "bench", "compile", "churn_compute.jl"))
using .ChurnCompute

function with_churn_repo(f)
    dir = mktempdir()
    try
        run(`git -C $dir init -q`)
        run(`git -C $dir config user.email test@example.com`)
        run(`git -C $dir config user.name test`)
        f(dir)
    finally
        rm(dir; force=true, recursive=true)
    end
    return nothing
end

function write_jl(dir, rel, text)
    path = joinpath(dir, rel)
    mkpath(dirname(path))
    write(path, text)
    return path
end

function git_commit(dir, msg)
    run(`git -C $dir add -A`)
    run(`git -C $dir commit -q -m $msg`)
    return nothing
end

@testset "churn compute" begin
    @testset "shallow history fails closed" begin
        with_churn_repo() do dir
            write_jl(dir, "src/Foo.jl", "module Foo\nend\n")
            git_commit(dir, "init")
            shallow = mktempdir()
            try
                run(`git -C $dir clone --depth 1 file://$dir $shallow`)
                @test_throws ErrorException ChurnCompute.compute_churn(shallow)
            finally
                rm(shallow; force=true, recursive=true)
            end
        end
    end

    @testset "rename following and move-only" begin
        with_churn_repo() do dir
            write_jl(dir, "src/Alpha.jl", "module Alpha\nline1\nline2\nend\n")
            git_commit(dir, "add alpha")
            old = joinpath(dir, "src", "Alpha.jl")
            new = joinpath(dir, "src", "Beta.jl")
            mv(old, new)
            git_commit(dir, "rename only")
            write(new, "module Beta\nline1\nline2\nline3\nend\n")
            git_commit(dir, "edit beta")
            report = ChurnCompute.compute_churn(dir; now=DateTime(2026, 1, 31, 15))
            row = only(report.areas)
            @test row.package == "DistSSHRun"
            @test row.added_30 >= 1
            @test row.added_30 - row.deleted_30 >= 1
        end
    end

    @testset "7d and 30d windows and removed paths" begin
        with_churn_repo() do dir
            fixed = DateTime(2026, 6, 15, 12)
            write_jl(dir, "src/Old.jl", "x = 1\n")
            ENV["GIT_AUTHOR_DATE"] = "2026-05-01T12:00:00"
            ENV["GIT_COMMITTER_DATE"] = "2026-05-01T12:00:00"
            git_commit(dir, "old file")
            delete!(ENV, "GIT_AUTHOR_DATE")
            delete!(ENV, "GIT_COMMITTER_DATE")
            write_jl(dir, "src/Keep.jl", "y = 1\n")
            ENV["GIT_AUTHOR_DATE"] = "2026-06-10T12:00:00"
            ENV["GIT_COMMITTER_DATE"] = "2026-06-10T12:00:00"
            git_commit(dir, "keep")
            rm(joinpath(dir, "src", "Old.jl"))
            ENV["GIT_AUTHOR_DATE"] = "2026-06-12T12:00:00"
            ENV["GIT_COMMITTER_DATE"] = "2026-06-12T12:00:00"
            git_commit(dir, "remove old")
            report = ChurnCompute.compute_churn(dir; now=fixed)
            @test any(r.path == "src/Old.jl" for r in report.removed)
            keep = only(filter(r -> occursin("Keep", r.area) || r.files == 1, report.areas))
            @test keep.added_7 >= 1
        end
    end

    @testset "area labels" begin
        @test ChurnCompute.area_label("DistSSHRun", "DistSSHRun.jl") == "DistSSHRun.jl"
        @test ChurnCompute.area_label("DistSSHRun", "cli/go/_using.jl") == "cli/"
        @test ChurnCompute.area_label("DistSSHBase", "ssh/foo.jl") == "ssh/"
        @test ChurnCompute.area_label("DistSSHBase", "tool.jl") == "(root files)"
    end
end