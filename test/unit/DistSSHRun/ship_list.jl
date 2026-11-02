using Test

@testset "ship gitignore send list" begin
    @testset "no git work tree" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, "Manifest.toml"), "# lock\n")
            write(joinpath(tmp, "a.jl"), "1\n")
            listed = DistSSHRun._ship_gitignore_send_list(tmp)
            @test listed isa Vector
            @test "Project.toml" in listed
            @test "a.jl" in listed
            packed = DistSSHRun.pack_ship_tar(tmp)
            try
                dest = mktempdir()
                DistSSHRun.Tar.extract(packed.tar_path, dest)
                @test isfile(joinpath(dest, "a.jl"))
                @test !isdir(joinpath(dest, ".git"))
            finally
                rm(packed.tmpd; force = true, recursive = true)
            end
        end
    end

    @testset "negation and ignored directories" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "data/*\n!data/keep.txt\noutput/*\nbuild/\n")
            mkpath(joinpath(tmp, "data"))
            write(joinpath(tmp, "data", "a.dat"), "x\n")
            write(joinpath(tmp, "data", "keep.txt"), "keep\n")
            mkpath(joinpath(tmp, "output"))
            write(joinpath(tmp, "output", "x.bin"), "x\n")
            mkpath(joinpath(tmp, "empty"))
            mkpath(joinpath(tmp, "build", "obj"))
            write(joinpath(tmp, "build", "obj", "a.o"), "o\n")
            listed = DistSSHRun._ship_gitignore_send_list(tmp)
            @test "data/keep.txt" in listed
            @test !("data/a.dat" in listed)
            @test "data" in listed
            @test "output" in listed
            @test !("output/x.bin" in listed)
            @test "empty" in listed
            @test !("build" in listed)
            @test !("build/obj/a.o" in listed)
        end
    end

    @testset "a negated pattern keeps an empty directory" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "*/\n!keep/\n")
            mkpath(joinpath(tmp, "keep"))
            mkpath(joinpath(tmp, "build"))
            listed = DistSSHRun._ship_gitignore_send_list(tmp)
            @test "keep" in listed
            @test !("build" in listed)
        end
    end

    @testset "an escaped bang still ignores the directory" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "\\!keep/\n")
            mkpath(joinpath(tmp, "!keep"))
            mkpath(joinpath(tmp, "plain"))
            listed = DistSSHRun._ship_gitignore_send_list(tmp)
            @test "plain" in listed
            @test !("!keep" in listed)
        end
    end

    @testset "directory symlink is listed" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            mkpath(joinpath(tmp, "vendor", "real"))
            write(joinpath(tmp, "vendor", "real", "x.jl"), "x = 1\n")
            symlink("real", joinpath(tmp, "vendor", "link"))
            listed = DistSSHRun._ship_gitignore_send_list(tmp)
            @test "vendor/link" in listed
            @test !("vendor/link/x.jl" in listed)
        end
    end

    @testset "path source follows the app gitignore" begin
        _with_tempdir() do tmp
            foo = joinpath(tmp, "vendor", "Foo")
            mkpath(joinpath(foo, "lib"))
            write(
                joinpath(tmp, "Project.toml"), """
                name = "App"
                [sources]
                Foo = {path = "vendor/Foo"}
                """
            )
            write(joinpath(tmp, ".gitignore"), "lib/\n")
            write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(foo, "lib", "x.jl"), "x = 1\n")
            listed = DistSSHRun._ship_gitignore_send_list(tmp)
            @test !("vendor/Foo/lib/x.jl" in listed)
            @test "vendor/Foo/Project.toml" in listed
        end
    end

    @testset "nested gitignore in a path source" begin
        _with_tempdir() do tmp
            dep = joinpath(tmp, "dep")
            mkpath(dep)
            write(joinpath(dep, ".gitignore"), "secret.txt\n")
            write(joinpath(dep, "keep.jl"), "k = 1\n")
            write(joinpath(dep, "secret.txt"), "nope\n")
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            listed = DistSSHRun._ship_gitignore_send_list(tmp)
            @test "dep/keep.jl" in listed
            @test !("dep/secret.txt" in listed)
        end
    end

    @testset "gitignore above the project is not used" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "dropped.txt\n")
            sub = joinpath(tmp, "sub")
            mkpath(sub)
            write(joinpath(sub, "Project.toml"), "name = \"App\"\n")
            write(joinpath(sub, "dropped.txt"), "nope\n")
            listed = DistSSHRun._ship_gitignore_send_list(sub)
            @test "dropped.txt" in listed
        end
    end

    @testset "a newline in a path is an error" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, "a\nb.txt"), "x\n")
            @test_throws ArgumentError DistSSHRun._ship_gitignore_send_list(tmp)
        end
    end

    @testset "gitignored project preferences still ship" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "LocalPreferences.toml\n")
            write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
            write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
            write(joinpath(tmp, "LocalPreferences.toml"), "[ShipT]\nx = 1\n")
            packed = DistSSHRun.pack_ship_tar(tmp)
            try
                dest = mktempdir()
                DistSSHRun.Tar.extract(packed.tar_path, dest)
                @test isfile(joinpath(dest, "LocalPreferences.toml"))
            finally
                rm(packed.tmpd; force = true, recursive = true)
            end
        end
    end
end
