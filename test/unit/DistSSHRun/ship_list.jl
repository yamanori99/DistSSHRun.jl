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


    @testset "a declared path source is shipped even when the parent gitignore names it" begin
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
                    @test isfile(joinpath(dest, "vendor", "Foo", "Project.toml"))
                    @test isfile(joinpath(dest, "vendor", "Foo", "src", "Foo.jl"))
                    @test isfile(joinpath(dest, "Project.toml"))
                finally
                    rm(packed.tmpd; force = true, recursive = true)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test !occursin("vendor/Foo/Project.toml", text)
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

    @testset "a workspace member ships under the workspace root" begin
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
                    @test isfile(joinpath(dest, "member", "Project.toml"))
                    @test occursin("Run1", read(joinpath(dest, "member", "Project.toml"), String))
                    @test isfile(joinpath(dest, "Project.toml"))
                    @test occursin("Lab", read(joinpath(dest, "Project.toml"), String))
                    @test isfile(joinpath(dest, "Manifest.toml"))
                    @test packed.project_rel == "member"
                finally
                    rm(packed.tmpd; force = true, recursive = true)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test !occursin("outside the ship root", text)
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

    @testset "a Manifest path outside the project ships under the common ancestor" begin
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
                    @test isfile(joinpath(dest, "app", "Project.toml"))
                    @test isfile(joinpath(dest, "app", "Manifest.toml"))
                    @test isfile(joinpath(dest, "shared", "Bar", "Project.toml"))
                    @test packed.project_rel == "app"
                finally
                    rm(packed.tmpd; force = true, recursive = true)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test !occursin("outside the ship root", text)
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

function _extracted_ship_rels(dest::AbstractString)::Vector{String}
    out = String[]
    for (dir, _, files) in walkdir(dest)
        rel = replace(relpath(dir, dest), '\\' => '/')
        rel == "." || push!(out, rel)
        for name in files
            child = rel == "." ? name : rel * "/" * name
            push!(out, child)
        end
    end
    return sort!(out)
end

@testset "ship_send_list" begin
    @testset "public and not exported" begin
        @test Base.ispublic(DistSSHRun, :ship_send_list)
        @test !Base.isexported(DistSSHRun, :ship_send_list)
    end

    @testset "an empty directory throws" begin
        _with_tempdir() do tmp
            @test_throws ArgumentError DistSSHRun.ship_send_list(tmp)
        end
    end

    @testset "a directory without a project file is listed" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "keep.jl"), "k = 1\n")
            @test DistSSHRun.ship_send_list(tmp) == ["keep.jl"]
        end
    end

    @testset "does not warn and does not run git" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "Project.toml\n")
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, "keep.jl"), "k = 1\n")
            listed, text = mktemp() do _, io
                got = redirect_stderr(io) do
                    redirect_stdout(io) do
                        DistSSHRun.ship_send_list(tmp)
                    end
                end
                flush(io)
                seekstart(io)
                return got, read(io, String)
            end
            @test listed == [".gitignore", "keep.jl"]
            @test !occursin("Warning", text)
            @test !occursin("fatal:", text)
        end
    end

    @testset "LocalPreferences.toml follows the gitignore" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "keep.jl"), "k = 1\n")
            write(joinpath(tmp, "LocalPreferences.toml"), "[App]\nx = 1\n")
            write(joinpath(tmp, ".gitignore"), "LocalPreferences.toml\n")
            @test !("LocalPreferences.toml" in DistSSHRun.ship_send_list(tmp))
            write(joinpath(tmp, ".gitignore"), "LocalPreferences.toml\n!LocalPreferences.toml\n")
            @test "LocalPreferences.toml" in DistSSHRun.ship_send_list(tmp)
        end
    end

    @testset "a newline in a path is an error" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "keep.jl"), "k = 1\n")
            write(joinpath(tmp, "a\nb.txt"), "x\n")
            @test_throws ArgumentError DistSSHRun.ship_send_list(tmp)
        end
    end

    @testset "an ignored newline path is skipped" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "*.tmp\n")
            write(joinpath(tmp, "keep.jl"), "k = 1\n")
            write(joinpath(tmp, "a\nb.tmp"), "x\n")
            listed = DistSSHRun.ship_send_list(tmp)
            @test listed == [".gitignore", "keep.jl"]
            @test !any(occursin('\n', r) for r in listed)
        end
    end

    @testset "tar members, declared inputs, and a fifo" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(
                joinpath(tmp, "Manifest.toml"),
                "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
            )
            write(joinpath(tmp, "keep.jl"), "k = 1\n")
            mkpath(joinpath(tmp, "nested", "sub"))
            write(joinpath(tmp, "nested", "sub", "a.jl"), "a = 1\n")
            mkpath(joinpath(tmp, "empty"))
            write(joinpath(tmp, ".gitignore"), "skip.txt\n")
            write(joinpath(tmp, "skip.txt"), "nope\n")
            mkpath(joinpath(tmp, "data"))
            write(joinpath(tmp, "data", "big.bin"), "payload\n")
            mkpath(joinpath(tmp, ".distsshkit"))
            write(
                joinpath(tmp, ".distsshkit", "inputs.toml"),
                """
                [[inputs]]
                name = "big"
                path = "data"
                hash = false
                """,
            )
            write(joinpath(tmp, ".distsshkit", "note.txt"), "kit\n")
            run(`mkfifo $(joinpath(tmp, "pipe"))`)
            listed = DistSSHRun.ship_send_list(tmp)
            @test listed == sort(listed)
            @test DistSSHRun.ship_send_list(tmp) == listed
            @test "keep.jl" in listed
            @test "nested" in listed
            @test "nested/sub" in listed
            @test "nested/sub/a.jl" in listed
            @test "empty" in listed
            @test !("skip.txt" in listed)
            @test !("data" in listed)
            @test !("data/big.bin" in listed)
            @test !("pipe" in listed)
            @test !any(
                r -> r == ".git" || startswith(r, ".git/") ||
                    r == ".distsshkit" || startswith(r, ".distsshkit/"), listed
            )
            @test !any(occursin('\\', r) for r in listed)
            omit = String[i.path for i in DistSSHRun._load_ship_inputs(tmp)]
            @test listed == DistSSHRun.DistSSHShip.send_paths(tmp; omit = omit)
            packed = DistSSHRun.pack_ship_tar(tmp)
            try
                @test DistSSHRun.ship_send_list(packed.root) == listed
                dest = mktempdir()
                DistSSHRun.Tar.extract(packed.tar_path, dest)
                @test _extracted_ship_rels(dest) == listed
                snap = DistSSHRun.DistSSHShip.snapshot(
                    tmp; omit_project_rels = omit,
                )
                try
                    @test snap.content_tree_hash == packed.hash
                finally
                    rm(snap.directory; force = true, recursive = true)
                end
            finally
                rm(packed.tmpd; force = true, recursive = true)
            end
        end
    end

    @testset "the same paths with and without .git" begin
        if _test_skip_unless_git()
            _with_tempdir() do tmp
                repo = joinpath(tmp, "repo")
                mkpath(repo)
                write(joinpath(repo, "Project.toml"), "name = \"App\"\n")
                write(
                    joinpath(repo, "Manifest.toml"),
                    "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
                )
                write(joinpath(repo, "tracked.jl"), "t = 1\n")
                write(joinpath(repo, "ignored.jl"), "i = 1\n")
                run(`git -C $repo init --quiet`)
                run(`git -C $repo config user.email t@t.t`)
                run(`git -C $repo config user.name t`)
                run(`git -C $repo add -A`)
                run(`git -C $repo commit --quiet -m init`)
                write(joinpath(repo, ".gitignore"), "ignored.jl\n")
                run(`git -C $repo add .gitignore`)
                run(`git -C $repo commit --quiet -m ignore`)
                write(joinpath(repo, "extra.jl"), "e = 1\n")
                plain = joinpath(tmp, "plain")
                cp(repo, plain)
                rm(joinpath(plain, ".git"); force = true, recursive = true)
                listed = DistSSHRun.ship_send_list(repo)
                @test listed == DistSSHRun.ship_send_list(plain)
                @test "tracked.jl" in listed
                @test "extra.jl" in listed
                @test ".gitignore" in listed
                @test !("ignored.jl" in listed)
                @test !any(r == ".git" || startswith(r, ".git/") for r in listed)
                env = DistSSHRun.resolve_pkg_env(repo)
                rsync = DistSSHRun.rsync_send_list(repo, env)
                @test rsync isa Vector
                @test "ignored.jl" in rsync
            end
        end
    end
end
