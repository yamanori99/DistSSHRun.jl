using Test

if !isdefined(@__MODULE__, :B)
    const B = DistSSHRun.DistSSHBase
end

@testset "resolve_pkg_project_dir skips vendored stubs" begin
    _with_tempdir() do tmp
        app = joinpath(tmp, "App")
        mkpath(app)
        write(joinpath(app, "Project.toml"), "name = \"App\"\n")
        for stub in ("DistSSHKit", "DistSSHQueue", "DistSSHRun")
            dir = joinpath(app, stub)
            mkpath(dir)
            write(joinpath(dir, "Project.toml"), "name = \"$(stub)\"\n")
            @test B.resolve_pkg_project_dir(dir) == abspath(app)
        end
        other = joinpath(app, "Other")
        mkpath(other)
        write(joinpath(other, "Project.toml"), "name = \"Other\"\n")
        @test B.resolve_pkg_project_dir(other) == abspath(other)
        lone = joinpath(tmp, "lone", "DistSSHRun")
        mkpath(lone)
        write(joinpath(lone, "Project.toml"), "name = \"DistSSHRun\"\n")
        @test B.resolve_pkg_project_dir(lone) == abspath(lone)
    end
end
