using Test
using Dates

const BENCH_COMPILE = joinpath(@__DIR__, "..")
include(joinpath(BENCH_COMPILE, "churn_compute.jl"))
using .ChurnCompute
include(joinpath(BENCH_COMPILE, "churn_report.jl"))

function with_churn_repo(f)
    dir = mktempdir()
    try
        run(`git -C $dir init -q`)
        run(`git -C $dir config user.email test@example.com`)
        run(`git -C $dir config user.name test`)
        f(dir)
    finally
        rm(dir; force = true, recursive = true)
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

function git_commit_at(dir, msg, when::AbstractString)
    withenv("GIT_AUTHOR_DATE" => when, "GIT_COMMITTER_DATE" => when) do
        git_commit(dir, msg)
    end
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
                rm(shallow; force = true, recursive = true)
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
            report = ChurnCompute.compute_churn(dir; now = DateTime(2026, 1, 31, 15))
            row = only(report.areas)
            @test row.package == "DistSSHRun"
            @test row.added_30 >= 1
            @test row.added_30 - row.deleted_30 >= 1
        end
    end

    @testset "rename and edit in one commit" begin
        with_churn_repo() do dir
            fixed = DateTime(2026, 6, 15, 12)
            write_jl(dir, "src/Alpha.jl", "module Alpha\none\nend\n")
            git_commit_at(dir, "add", "2026-06-01T12:00:00")
            mv(joinpath(dir, "src", "Alpha.jl"), joinpath(dir, "src", "Beta.jl"))
            write(joinpath(dir, "src", "Beta.jl"), "module Beta\none\ntwo\nthree\nend\n")
            git_commit_at(dir, "rename edit", "2026-06-14T12:00:00")
            report = ChurnCompute.compute_churn(dir; now = fixed)
            row = only(report.areas)
            @test row.added_30 >= 2
        end
    end

    @testset "7d and 30d windows and removed paths" begin
        with_churn_repo() do dir
            fixed = DateTime(2026, 6, 15, 12)
            write_jl(dir, "src/Old.jl", "x = 1\n")
            git_commit_at(dir, "old file", "2026-05-01T12:00:00")
            write_jl(dir, "src/Keep.jl", "y = 1\n")
            git_commit_at(dir, "keep", "2026-06-10T12:00:00")
            rm(joinpath(dir, "src", "Old.jl"))
            git_commit_at(dir, "remove old", "2026-06-12T12:00:00")
            report = ChurnCompute.compute_churn(dir; now = fixed)
            @test any(r.path == "src/Old.jl" for r in report.removed)
            keep = only(filter(r -> occursin("Keep", r.area) || r.files == 1, report.areas))
            @test keep.added_7 >= 1
        end
    end

    @testset "30d window excludes older churn" begin
        with_churn_repo() do dir
            fixed = DateTime(2026, 6, 15, 12)
            path = write_jl(dir, "src/Stale.jl", "a = 1\n")
            git_commit_at(dir, "stale", "2026-04-01T12:00:00")
            write(path, "a = 1\nb = 2\n")
            git_commit_at(dir, "recent", "2026-06-10T12:00:00")
            report = ChurnCompute.compute_churn(dir; now = fixed)
            row = only(report.areas)
            @test row.added_30 == 1
        end
    end

    @testset "map_to_head chains renames within a commit" begin
        commits = ["c1", "c2"]
        per = [
            Dict{String, String}(),
            Dict("src/A.jl" => "src/B.jl", "src/B.jl" => "src/C.jl"),
        ]
        @test ChurnCompute.map_to_head("src/A.jl", 1, commits, per) == "src/C.jl"
    end

    @testset "normalize_numstat_path" begin
        @test ChurnCompute.normalize_numstat_path("src/A.jl => src/B.jl") == "src/B.jl"
        @test ChurnCompute.normalize_numstat_path("src/X.jl") == "src/X.jl"
    end

    @testset "area labels" begin
        @test ChurnCompute.area_label("DistSSHRun", "DistSSHRun.jl") == "DistSSHRun.jl"
        @test ChurnCompute.area_label("DistSSHRun", "cli/go/_using.jl") == "cli/"
        @test ChurnCompute.area_label("DistSSHRun", "DistSSHRun/core/drive/run.jl") == "core/drive/"
        @test ChurnCompute.area_label("DistSSHRun", "DistSSHRun/drive.jl") == "(root files)"
        @test ChurnCompute.area_label("DistSSHBase", "ssh/foo.jl") == "ssh/"
        @test ChurnCompute.area_label("DistSSHBase", "tool.jl") == "(root files)"
    end

    @testset "area row inclusion" begin
        @test !ChurnCompute.area_row_included(
            ChurnCompute.AreaRow(
                "DistSSHRun", "core/", 0, 0, 0, 0, 0, 0, 100.0, nothing, String[],
            )
        )
        @test ChurnCompute.area_row_included(
            ChurnCompute.AreaRow(
                "DistSSHRun", "core/", 1, 10, 0, 0, 5, 0, 100.0, nothing, String[],
            )
        )
    end

    @testset "nested dirs and zero churn rows" begin
        with_churn_repo() do dir
            fixed = DateTime(2026, 6, 15, 12)
            write_jl(dir, "src/DistSSHRun.jl", "module DistSSHRun\nend\n")
            write_jl(dir, "src/DistSSHRun/core/drive/run.jl", "x = 1\n")
            git_commit_at(dir, "init nested", "2026-01-01T12:00:00")
            write(
                joinpath(dir, "src", "DistSSHRun", "core", "drive", "run.jl"),
                "x = 1\ny = 2\n",
            )
            git_commit_at(dir, "edit drive", "2026-06-10T12:00:00")
            report = ChurnCompute.compute_churn(dir; now = fixed)
            areas = [r.area for r in report.areas if r.package == "DistSSHRun"]
            @test "core/drive/" in areas
            @test !("core/" in areas)
            @test !any(r -> r.area == "DistSSHRun.jl", report.areas)
        end
    end

    @testset "splice churn generated into docs page" begin
        dir = mktempdir()
        try
            doc = joinpath(dir, "source_churn.md")
            write(
                doc,
                "# Source churn\n\nintro\n\n$(CHURN_GENERATED_BEGIN)\nold\n$(CHURN_GENERATED_END)\n",
            )
            splice_churn_generated(doc, "new table\n\n![summary](https://example.test/churn-summary.png)")
            text = read(doc, String)
            @test occursin("new table", text)
            @test !occursin("\nold\n", text)
            @test occursin("https://example.test/churn-summary.png", text)
            @test occursin("# Source churn", text)
        finally
            rm(dir; force = true, recursive = true)
        end
    end

    @testset "interactive html charts" begin
        include(joinpath(BENCH_COMPILE, "churn_charts_html.jl"))
        week = Date(2026, 6, 9)
        row = ChurnCompute.AreaRow(
            "DistSSHRun", "cli/", 2, 100, 1, 0, 5, 1, 50.0, Date(2026, 6, 1), String[],
        )
        report = ChurnCompute.ChurnReport(
            "0123456789abcdef0123456789abcdef01234567",
            Date(2026, 6, 15),
            DateTime(2026, 6, 15, 3),
            [row],
            ChurnCompute.RemovedPathRow[],
            Dict("DistSSHRun/cli/" => Pair{Date, Int}[week => 3]),
            Dict(week => 5),
            Dict(week => 1),
        )
        dir = mktempdir()
        try
            write_churn_html_charts(report, dir)
            for name in ("churn-summary.html", "churn-weekly.html", "churn-heatmap.html")
                path = joinpath(dir, name)
                @test isfile(path)
                text = read(path, String)
                @test occursin(CHURN_PLOTLY_CDN, text)
                @test count("<script", text) == 2
                @test !occursin("/*! plotly.js", text)
                @test stat(path).size < CHURN_HTML_MAX_BYTES
            end
            md = render_churn_markdown(report, "charts")
            @test occursin("churn-summary.html", md)
            @test occursin("churn-weekly.html", md)
            @test occursin("churn-heatmap.html", md)
        finally
            rm(dir; force = true, recursive = true)
        end
    end
end
