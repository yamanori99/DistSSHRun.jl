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
            packed, err = mktemp() do _, io
                p = redirect_stderr(io) do
                    DistSSHRun.pack_ship_tar(tmp)
                end
                flush(io)
                seekstart(io)
                return p, read(io, String)
            end
            try
                dest = mktempdir()
                DistSSHRun.Tar.extract(packed.tar_path, dest)
                @test isfile(joinpath(dest, "a.jl"))
                @test !isdir(joinpath(dest, ".git"))
                @test !occursin("fatal:", err)
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

    @testset "an ignored newline path is skipped" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "*.tmp\n")
            write(joinpath(tmp, "a\nb.tmp"), "x\n")
            listed = DistSSHRun._ship_gitignore_send_list(tmp)
            @test "Project.toml" in listed
            @test !any(occursin('\n', r) for r in listed)
        end
    end


    @testset "a gitignored path source is left out" begin
        _with_tempdir() do tmp
            foo = joinpath(tmp, "vendor", "Foo")
            mkpath(joinpath(foo, "src"))
            write(
                joinpath(tmp, "Project.toml"), """
                name = "App"
                [sources]
                Foo = {path = "vendor/Foo"}
                """
            )
            write(joinpath(tmp, "Manifest.toml"), "# lock\n")
            write(joinpath(tmp, ".gitignore"), "vendor/\n")
            write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(foo, "src", "Foo.jl"), "module Foo end\n")
            text = mktemp() do _, io
                packed = redirect_stdout(io) do
                    DistSSHRun.pack_ship_tar(tmp)
                end
                try
                    dest = mktempdir()
                    DistSSHRun.Tar.extract(packed.tar_path, dest)
                    @test !isdir(joinpath(dest, "vendor"))
                    @test isfile(joinpath(dest, "Project.toml"))
                finally
                    rm(packed.tmpd; force = true, recursive = true)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test occursin("vendor/Foo/Project.toml", text)
            @test occursin("will not be shipped", text)
        end
    end

    @testset "a Manifest url dep is not treated as a path source" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(
                joinpath(tmp, "Manifest.toml"), """
                julia_version = "1.13.0"
                manifest_format = "2.0"
                [[deps.Foo]]
                git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                repo-url = "https://example.com/Foo.jl.git"
                uuid = "00000000-0000-0000-0000-000000000001"
                version = "0.1.0"
                """
            )
            write(joinpath(tmp, "a.jl"), "1\n")
            packed = DistSSHRun.pack_ship_tar(tmp)
            try
                dest = mktempdir()
                DistSSHRun.Tar.extract(packed.tar_path, dest)
                @test isfile(joinpath(dest, "Project.toml"))
            finally
                rm(packed.tmpd; force = true, recursive = true)
            end
        end
    end

    @testset "a gitignored selected Project.toml warns and the rest ships" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, "Manifest.toml"), "# lock\n")
            write(joinpath(tmp, "a.jl"), "1\n")
            write(joinpath(tmp, ".gitignore"), "Project.toml\n")
            text = mktemp() do _, io
                packed = redirect_stdout(io) do
                    DistSSHRun.pack_ship_tar(tmp)
                end
                try
                    dest = mktempdir()
                    DistSSHRun.Tar.extract(packed.tar_path, dest)
                    @test !isfile(joinpath(dest, "Project.toml"))
                    @test isfile(joinpath(dest, "a.jl"))
                    @test isfile(joinpath(dest, "Manifest.toml"))
                finally
                    rm(packed.tmpd; force = true, recursive = true)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test occursin("Project.toml", text)
            @test occursin("will not be shipped", text)
        end
    end

    @testset "a workspace member ships alone" begin
        _with_tempdir() do lab
            member = joinpath(lab, "member")
            mkpath(member)
            write(
                joinpath(lab, "Project.toml"), """
                name = "Lab"
                [workspace]
                projects = ["member"]
                """
            )
            write(joinpath(lab, "Manifest.toml"), "# lock\n")
            write(
                joinpath(member, "Project.toml"), """
                name = "Run1"
                [sources]
                Lab = {path = ".."}
                """
            )
            text = mktemp() do _, io
                packed = redirect_stdout(io) do
                    DistSSHRun.pack_ship_tar(member)
                end
                try
                    dest = mktempdir()
                    DistSSHRun.Tar.extract(packed.tar_path, dest)
                    @test isfile(joinpath(dest, "Project.toml"))
                    @test occursin("Run1", read(joinpath(dest, "Project.toml"), String))
                    @test !isfile(joinpath(dest, "Manifest.toml"))
                    @test !isdir(joinpath(dest, "member"))
                finally
                    rm(packed.tmpd; force = true, recursive = true)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test occursin("outside the ship root", text)
            wider = DistSSHRun.pack_ship_tar(lab)
            try
                dest = mktempdir()
                DistSSHRun.Tar.extract(wider.tar_path, dest)
                @test isfile(joinpath(dest, "Project.toml"))
                @test isfile(joinpath(dest, "member", "Project.toml"))
                @test isfile(joinpath(dest, "Manifest.toml"))
            finally
                rm(wider.tmpd; force = true, recursive = true)
            end
        end
    end

    @testset "a Manifest path outside the ship root warns" begin
        _with_tempdir() do tmp
            app = joinpath(tmp, "app")
            bar = joinpath(tmp, "shared", "Bar")
            mkpath(app)
            mkpath(joinpath(bar, "src"))
            write(joinpath(app, "Project.toml"), "name = \"App\"\n")
            write(
                joinpath(app, "Manifest.toml"), """
                julia_version = "1.13.0"
                manifest_format = "2.0"
                [[deps.Bar]]
                path = "../shared/Bar"
                uuid = "00000000-0000-0000-0000-000000000001"
                version = "0.1.0"
                """
            )
            write(joinpath(bar, "Project.toml"), "name = \"Bar\"\n")
            text = mktemp() do _, io
                packed = redirect_stdout(io) do
                    DistSSHRun.pack_ship_tar(app)
                end
                try
                    dest = mktempdir()
                    DistSSHRun.Tar.extract(packed.tar_path, dest)
                    @test isfile(joinpath(dest, "Project.toml"))
                    @test !isdir(joinpath(dest, "shared"))
                finally
                    rm(packed.tmpd; force = true, recursive = true)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test occursin("outside the ship root", text)
            @test occursin("Bar", text)
        end
    end

    @testset "an absolute source path is still refused" begin
        _with_tempdir() do tmp
            foo = joinpath(tmp, "vendor", "Foo")
            mkpath(foo)
            write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
            absfoo = replace(foo, '\\' => '/')
            write(
                joinpath(tmp, "Project.toml"), """
                name = "App"
                [sources]
                Foo = {path = "$absfoo"}
                """
            )
            write(joinpath(tmp, "Manifest.toml"), "# lock\n")
            err = try
                DistSSHRun.pack_ship_tar(tmp)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("absolute", err.msg)
        end
    end

    @testset "a path source under a directory symlink uses the target" begin
        _with_tempdir() do tmp
            real = joinpath(tmp, "vendor", "real", "Foo")
            mkpath(joinpath(real, "src"))
            write(joinpath(real, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(real, "src", "Foo.jl"), "module Foo end\n")
            mkpath(joinpath(tmp, "vendor"))
            symlink("real", joinpath(tmp, "vendor", "link"))
            write(
                joinpath(tmp, "Project.toml"), """
                name = "App"
                [sources]
                Foo = {path = "vendor/link/Foo"}
                """
            )
            write(joinpath(tmp, "Manifest.toml"), "# lock\n")
            packed = DistSSHRun.pack_ship_tar(tmp)
            try
                dest = mktempdir()
                DistSSHRun.Tar.extract(packed.tar_path, dest)
                @test islink(joinpath(dest, "vendor", "link"))
                @test isfile(joinpath(dest, "vendor", "real", "Foo", "Project.toml"))
            finally
                rm(packed.tmpd; force = true, recursive = true)
            end
        end
    end

    @testset "gitignored project preferences stay out" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "LocalPreferences.toml\n")
            write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
            write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
            write(joinpath(tmp, "LocalPreferences.toml"), "[ShipT]\nx = 1\n")
            packed = DistSSHRun.pack_ship_tar(tmp)
            try
                dest = mktempdir()
                DistSSHRun.Tar.extract(packed.tar_path, dest)
                @test !isfile(joinpath(dest, "LocalPreferences.toml"))
                @test isfile(joinpath(dest, "Project.toml"))
            finally
                rm(packed.tmpd; force = true, recursive = true)
            end
        end
    end

    @testset "a negation pattern ships LocalPreferences.toml" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "LocalPreferences.toml\n!LocalPreferences.toml\n")
            write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
            write(joinpath(tmp, "Manifest.toml"), "# lock\n")
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

    @testset "a Manifest behind a directory symlink is covered" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            mkpath(joinpath(tmp, "real"))
            write(joinpath(tmp, "real", "Manifest.toml"), "# lock\n")
            symlink("real", joinpath(tmp, "link"))
            symlink(joinpath("link", "Manifest.toml"), joinpath(tmp, "Manifest.toml"))
            packed = DistSSHRun.pack_ship_tar(tmp)
            try
                dest = mktempdir()
                DistSSHRun.Tar.extract(packed.tar_path, dest)
                @test isfile(joinpath(dest, "Project.toml"))
                @test islink(joinpath(dest, "Manifest.toml")) || isfile(joinpath(dest, "real", "Manifest.toml"))
            finally
                rm(packed.tmpd; force = true, recursive = true)
            end
        end
    end

    @testset "nested git still applies the parent gitignore" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, "Manifest.toml"), "# lock\n")
            write(joinpath(tmp, ".gitignore"), "*.csv\n")
            sub = joinpath(tmp, "sub", "assets")
            mkpath(sub)
            write(joinpath(tmp, "sub", "inside.jl"), "i = 1\n")
            write(joinpath(sub, "table.csv"), "a,b\n")
            mkpath(joinpath(tmp, "sub", ".git"))
            write(joinpath(tmp, "sub", ".git", "HEAD"), "ref: refs/heads/main\n")
            listed = DistSSHRun._ship_gitignore_send_list(tmp)
            @test "sub/inside.jl" in listed
            @test !("sub/assets/table.csv" in listed)
        end
    end

    @testset "gitignored preferences beside JuliaProject.toml stay out" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "LocalPreferences.toml\n")
            write(joinpath(tmp, "JuliaProject.toml"), "name = \"ShipT\"\n")
            write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
            write(joinpath(tmp, "LocalPreferences.toml"), "[ShipT]\nx = 1\n")
            packed = DistSSHRun.pack_ship_tar(tmp)
            try
                dest = mktempdir()
                DistSSHRun.Tar.extract(packed.tar_path, dest)
                @test !isfile(joinpath(dest, "LocalPreferences.toml"))
                @test isfile(joinpath(dest, "JuliaProject.toml"))
            finally
                rm(packed.tmpd; force = true, recursive = true)
            end
        end
    end
end
