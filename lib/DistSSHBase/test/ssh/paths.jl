using Test

@testset "paths" begin
    @testset "resolve_pkg_project_dir matches Base.current_project" begin
        _with_tempdir() do tmp
            app = joinpath(tmp, "App")
            mkpath(app)
            write(joinpath(app, "Project.toml"), "name = \"App\"\n")
            for stub in ("DistSSHKit", "DistSSHQueue", "DistSSHRun")
                dir = joinpath(app, stub)
                mkpath(dir)
                write(joinpath(dir, "Project.toml"), "name = \"$(stub)\"\n")
                @test DistSSHBase.resolve_pkg_project_dir(dir) == abspath(dir)
                @test DistSSHBase.current_project_file(dir) == abspath(joinpath(dir, "Project.toml"))
            end
            other = joinpath(app, "Other")
            mkpath(other)
            write(joinpath(other, "Project.toml"), "name = \"Other\"\n")
            @test DistSSHBase.resolve_pkg_project_dir(other) == abspath(other)
            lone = joinpath(tmp, "lone", "DistSSHRun")
            mkpath(lone)
            write(joinpath(lone, "Project.toml"), "name = \"DistSSHRun\"\n")
            @test DistSSHBase.resolve_pkg_project_dir(lone) == abspath(lone)
            scripts = joinpath(app, "scripts", "deep")
            mkpath(scripts)
            @test DistSSHBase.resolve_pkg_project_dir(scripts) == abspath(app)
        end
    end

    @testset "julia_sysimage_is_default" begin
        @test DistSSHBase.julia_sysimage_is_default()
        @test isfile(DistSSHBase.julia_sysimage_path())
    end

    @testset "local paths" begin
        _with_tempdir() do tmp
            rel = joinpath(tmp, "nested")
            mkpath(rel)
            @test DistSSHBase.canonical_local_path(rel) == abspath(rel)
            @test DistSSHBase.canonical_local_path(joinpath("~", ".ssh")) ==
                abspath(expanduser(joinpath("~", ".ssh")))
        end

        let home = expanduser("~")
            @test DistSSHBase.short_path(joinpath(home, "foo", "bar")) == joinpath("~", "foo", "bar")
        end

        _with_tempdir() do tmp
            nested = joinpath(tmp, "a", "b.txt")
            mkpath(dirname(nested))
            write(nested, "")
            @test DistSSHBase.display_path(nested, tmp) == joinpath("a", "b.txt")
        end
    end

    @testset "project layout" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"DistSSHRun\"\n")
            @test DistSSHBase.resolve_pkg_project_dir(tmp) == tmp
            @test DistSSHBase.project_package_name(tmp) == "DistSSHRun"
        end
        _with_tempdir() do tmp
            @test DistSSHBase.project_package_name(tmp) === nothing
            write(joinpath(tmp, "Project.toml"), "name = \"FooBar\"\n")
            @test DistSSHBase.project_package_name(tmp) == "FooBar"
        end
        @test DistSSHBase._path_is_under("/a/b/c", "/a/b")
        @test DistSSHBase._path_is_under("/a/b", "/a/b")
        @test !DistSSHBase._path_is_under("/a/bother", "/a/b")
    end

    @testset "_path_under_resolved" begin
        _with_tempdir() do base
            root = joinpath(base, "proj")
            mkpath(joinpath(root, "in"))
            write(joinpath(root, "in", "ok.jl"), "")
            outside = joinpath(base, "outside.jl")
            write(outside, "")
            escape = joinpath(root, "escape.jl")
            symlink(outside, escape)
            @test !DistSSHBase._path_under_resolved(escape, root)
            missing_via = joinpath(root, "escape.jl", "missing.jl")
            @test !DistSSHBase._path_under_resolved(missing_via, root)
            @test DistSSHBase._path_under_resolved(joinpath(root, "in", "ok.jl"), root)
            @test DistSSHBase._path_under_resolved(joinpath(root, "in", "missing.jl"), root)

            link_root = joinpath(base, "link_proj")
            symlink(root, link_root)
            @test DistSSHBase._path_under_resolved(joinpath(link_root, "in", "ok.jl"), link_root)
            @test DistSSHBase._path_under_resolved(joinpath(link_root, "in", "ok.jl"), root)
        end
        _with_tempdir() do base
            write(joinpath(base, "x.jl"), "")
            priv = "/private" * base
            if ispath(priv)
                @test DistSSHBase._path_under_resolved(joinpath(base, "x.jl"), priv)
                @test DistSSHBase._path_under_resolved(joinpath(priv, "x.jl"), base)
            end
        end
    end

    @testset "resolve_host_project_abs parent" begin
        _with_tempdir() do tmp
            p = abspath(tmp)
            @test DistSSHBase.resolve_host_project_abs("parent", p) ==
                DistSSHBase.canonical_local_path(p)
            @test DistSSHBase.resolve_host_path_abs("parent", joinpath(p, "sub"), p) ==
                DistSSHBase.canonical_local_path(joinpath(p, "sub"))
            @test !DistSSHBase.is_parent_host_name("localhost")
        end
    end

    @testset "resolve_host_path_abs absolute remote map" begin
        _with_tempdir() do tmp
            p = DistSSHBase.canonical_local_path(tmp)
            withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/remote/App") do
                @test DistSSHBase.resolve_host_project_abs("some-host", p) == "/remote/App"
                @test DistSSHBase.resolve_host_path_abs("some-host", joinpath(p, "src"), p) ==
                    joinpath("/remote/App", "src") |> abspath
            end
            withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/remote/App\nbad") do
                @test_throws ArgumentError DistSSHBase.resolve_host_project_abs("some-host", p)
            end
        end
    end
end
