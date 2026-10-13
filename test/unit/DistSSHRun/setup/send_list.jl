using Test

# Oracle: `_rsync_send_list` against a temporary git repository. No rsync, no SSH.

@testset "rsync send list" begin
    function _ident!(dir)
        run(pipeline(`git -C $dir config user.email "test@example.com"`; stdout = devnull, stderr = devnull))
        run(pipeline(`git -C $dir config user.name "Test"`; stdout = devnull, stderr = devnull))
        return nothing
    end

    function _commit!(dir, message)
        run(pipeline(`git -C $dir add -A`; stdout = devnull, stderr = devnull))
        run(pipeline(`git -C $dir commit -q -m $message`; stdout = devnull, stderr = devnull))
        return nothing
    end

    Sys.which("git") === nothing && return

    @testset "negation, info/exclude, and deleted files" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "data/*\n!data/keep.txt\n")
            mkpath(joinpath(tmp, "data"))
            write(joinpath(tmp, "data", "a.dat"), "x\n")
            write(joinpath(tmp, "data", "keep.txt"), "keep\n")
            write(joinpath(tmp, "gone.txt"), "gone\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            _commit!(tmp, "init")
            rm(joinpath(tmp, "gone.txt"))
            mkpath(joinpath(tmp, ".git", "info"))
            write(joinpath(tmp, ".git", "info", "exclude"), "secret.txt\n")
            write(joinpath(tmp, "secret.txt"), "nope\n")
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test listed isa Vector
            @test "data/keep.txt" in listed
            @test !("data/a.dat" in listed)
            @test !("secret.txt" in listed)
            @test !("gone.txt" in listed)
        end
    end

    @testset "path source ignores the app gitignore" begin
        _with_tempdir() do tmp
            foo = joinpath(tmp, "vendor", "Foo")
            mkpath(joinpath(foo, "lib"))
            write(joinpath(tmp, "Project.toml"), """
            name = "App"
            [sources]
            Foo = {path = "vendor/Foo"}
            """)
            write(joinpath(tmp, ".gitignore"), "lib/\n")
            write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(foo, "lib", "x.jl"), "x = 1\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            _commit!(tmp, "init")
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "vendor/Foo/lib/x.jl" in listed
        end
    end

    @testset "independent path source uses its own gitignore" begin
        _with_tempdir() do tmp
            dep = joinpath(tmp, "dep")
            mkpath(dep)
            write(joinpath(dep, ".gitignore"), "secret.txt\n")
            write(joinpath(dep, "keep.jl"), "k = 1\n")
            write(joinpath(dep, "secret.txt"), "nope\n")
            run(pipeline(`git -C $dep init -q`; stdout = devnull, stderr = devnull))
            _ident!(dep)
            _commit!(dep, "dep")
            write(joinpath(tmp, "Project.toml"), """
            name = "App"
            [sources]
            Dep = {path = "dep"}
            """)
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            _commit!(tmp, "app")
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "dep/keep.jl" in listed
            @test !("dep/secret.txt" in listed)
        end
    end

    @testset "nested repo and submodule are expanded" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            _commit!(tmp, "app")
            nested = joinpath(tmp, "nested")
            mkpath(nested)
            write(joinpath(nested, "a.jl"), "a = 1\n")
            run(pipeline(`git -C $nested init -q`; stdout = devnull, stderr = devnull))
            _ident!(nested)
            _commit!(nested, "nested")
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "nested/a.jl" in listed

            child = joinpath(tmp, "child-src")
            mkpath(child)
            write(joinpath(child, "inside.jl"), "i = 1\n")
            run(pipeline(`git -C $child init -q`; stdout = devnull, stderr = devnull))
            _ident!(child)
            _commit!(child, "child")
            sub = joinpath(tmp, "sub")
            run(pipeline(`git clone -q $child $sub`; stdout = devnull, stderr = devnull))
            sha = strip(read(`git -C $sub rev-parse HEAD`, String))
            run(pipeline(`git -C $tmp update-index --add --cacheinfo 160000,$sha,sub`; stdout = devnull, stderr = devnull))
            _commit!(tmp, "gitlink")
            listed2 = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "sub/inside.jl" in listed2
        end
    end

    @testset "outside a work tree the caller keeps the filter" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            @test DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp)) === nothing
        end
    end

    @testset "a newline in a path is an error" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, "a\nb.txt"), "x\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            _commit!(tmp, "nl")
            @test_throws ArgumentError DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
        end
    end
end
