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

    @testset "a gitignored path source is refused" begin
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
            err = try
                DistSSHRun.pack_ship_tar(tmp)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("Source path vendor/Foo for Foo is not in the rsync send list", err.msg)
        end
    end

    @testset "a gitignored path-source Project.toml is refused" begin
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
            write(joinpath(tmp, ".gitignore"), "vendor/Foo/Project.toml\n")
            write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(foo, "src", "Foo.jl"), "module Foo end\n")
            err = try
                DistSSHRun.pack_ship_tar(tmp)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("Source path vendor/Foo/Project.toml for Foo is not in the rsync send list", err.msg)
        end
    end

    @testset "a gitignored Manifest path dep is refused" begin
        _with_tempdir() do tmp
            foo = joinpath(tmp, "vendor", "Foo")
            mkpath(joinpath(foo, "src"))
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(
                joinpath(tmp, "Manifest.toml"), """
                julia_version = "1.13.0"
                manifest_format = "2.0"
                [[deps.Foo]]
                path = "vendor/Foo"
                uuid = "00000000-0000-0000-0000-000000000001"
                version = "0.1.0"
                """
            )
            write(joinpath(tmp, ".gitignore"), "vendor/\n")
            write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(foo, "src", "Foo.jl"), "module Foo end\n")
            err = try
                DistSSHRun.pack_ship_tar(tmp)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("Source path vendor/Foo for Foo is not in the rsync send list", err.msg)
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

    @testset "a Manifest path of the env root is the clone itself" begin
        if Sys.which("git") === nothing
            @test_skip "git is not on PATH"
        else
            _with_tempdir() do tmp
                write(joinpath(tmp, "Project.toml"), "name = \"App\"\nuuid = \"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\"\n")
                write(
                    joinpath(tmp, "Manifest.toml"), """
                    julia_version = "1.13.0"
                    manifest_format = "2.0"
                    [[deps.App]]
                    path = "."
                    uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
                    version = "0.0.1"
                    """
                )
                run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $tmp config user.email "test@example.com"`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $tmp config user.name "Test"`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $tmp add Project.toml Manifest.toml`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $tmp -c commit.gpgsign=false commit -q -m init`; stdout = devnull, stderr = devnull))
                @test DistSSHRun.ensure_manifest_in_git_worktree!(tmp) === nothing
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
    end

    @testset "a format-1 Manifest path dep is refused" begin
        _with_tempdir() do tmp
            foo = joinpath(tmp, "vendor", "Foo")
            mkpath(joinpath(foo, "src"))
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(
                joinpath(tmp, "Manifest.toml"), """
                [[Foo]]
                path = "vendor/Foo"
                uuid = "00000000-0000-0000-0000-000000000001"
                version = "0.1.0"
                [deps]
                Foo = "00000000-0000-0000-0000-000000000001"
                """
            )
            write(joinpath(tmp, ".gitignore"), "vendor/\n")
            write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(foo, "src", "Foo.jl"), "module Foo end\n")
            err = try
                DistSSHRun.pack_ship_tar(tmp)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("Source path vendor/Foo for Foo is not in the rsync send list", err.msg)
        end
    end

    @testset "a gitignored selected Project.toml is refused" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, "Manifest.toml"), "# lock\n")
            write(joinpath(tmp, "a.jl"), "1\n")
            write(joinpath(tmp, ".gitignore"), "Project.toml\n")
            err = try
                DistSSHRun.pack_ship_tar(tmp)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("Project Project.toml is not in the rsync send list", err.msg)
        end
    end

    @testset "a gitignored Manifest symlink target is refused" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            mkpath(joinpath(tmp, "hidden"))
            write(joinpath(tmp, "hidden", "Manifest.toml"), "# lock\n")
            symlink(joinpath("hidden", "Manifest.toml"), joinpath(tmp, "Manifest.toml"))
            write(joinpath(tmp, ".gitignore"), "hidden/\n")
            err = try
                DistSSHRun.pack_ship_tar(tmp)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("points at hidden/Manifest.toml", err.msg)
            @test occursin("not in the rsync send list", err.msg)
        end
    end

    @testset "a workspace source at the env root is covered" begin
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
            packed = DistSSHRun.pack_ship_tar(member)
            try
                dest = mktempdir()
                DistSSHRun.Tar.extract(packed.tar_path, dest)
                @test isfile(joinpath(dest, "Project.toml"))
                @test isfile(joinpath(dest, "member", "Project.toml"))
            finally
                rm(packed.tmpd; force = true, recursive = true)
            end
        end
    end

    @testset "a gitignored ..vendor path source is refused" begin
        _with_tempdir() do tmp
            foo = joinpath(tmp, "..vendor", "Foo")
            mkpath(joinpath(foo, "src"))
            write(
                joinpath(tmp, "Project.toml"), """
                name = "App"
                [sources]
                Foo = {path = "..vendor/Foo"}
                """
            )
            write(joinpath(tmp, "Manifest.toml"), "# lock\n")
            write(joinpath(tmp, ".gitignore"), "..vendor/\n")
            write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(foo, "src", "Foo.jl"), "module Foo end\n")
            err = try
                DistSSHRun.pack_ship_tar(tmp)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("Source path ..vendor/Foo for Foo is not in the rsync send list", err.msg)
        end
    end

    @testset "an intermediate Manifest symlink must be listed" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            mkpath(joinpath(tmp, "hidden"))
            mkpath(joinpath(tmp, "visible"))
            write(joinpath(tmp, "visible", "Manifest.toml"), "# lock\n")
            symlink(joinpath("..", "visible", "Manifest.toml"), joinpath(tmp, "hidden", "mid"))
            symlink(joinpath("hidden", "mid"), joinpath(tmp, "Manifest.toml"))
            write(joinpath(tmp, ".gitignore"), "hidden/\n")
            err = try
                DistSSHRun.pack_ship_tar(tmp)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("points at hidden/mid", err.msg)
            @test occursin("not in the rsync send list", err.msg)
        end
    end

    @testset "a path-source symlink to a gitignored target is refused" begin
        _with_tempdir() do tmp
            real = joinpath(tmp, "vendor", "real")
            mkpath(joinpath(real, "src"))
            write(joinpath(real, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(real, "src", "Foo.jl"), "module Foo end\n")
            mkpath(joinpath(tmp, "vendor"))
            symlink("real", joinpath(tmp, "vendor", "Foo"))
            write(
                joinpath(tmp, "Project.toml"), """
                name = "App"
                [sources]
                Foo = {path = "vendor/Foo"}
                """
            )
            write(joinpath(tmp, "Manifest.toml"), "# lock\n")
            write(joinpath(tmp, ".gitignore"), "vendor/real/\n")
            err = try
                DistSSHRun.pack_ship_tar(tmp)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("Source path vendor/Foo for Foo is not in the rsync send list", err.msg)
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

    @testset "a Manifest path outside the git tree is a ship-tree check" begin
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
            write(joinpath(bar, "src", "Bar.jl"), "module Bar end\n")
            if Sys.which("git") !== nothing
                withenv("GIT_DIR" => nothing, "GIT_WORK_TREE" => nothing, "GIT_INDEX_FILE" => nothing) do
                    run(pipeline(`git -C $app init -q`; stdout = devnull, stderr = devnull))
                    run(pipeline(`git -C $app config user.email "test@example.com"`; stdout = devnull, stderr = devnull))
                    run(pipeline(`git -C $app config user.name "Test"`; stdout = devnull, stderr = devnull))
                    run(pipeline(`git -C $app add Project.toml Manifest.toml`; stdout = devnull, stderr = devnull))
                    run(pipeline(`git -C $app -c commit.gpgsign=false commit -q -m init`; stdout = devnull, stderr = devnull))
                    @test DistSSHRun.ensure_manifest_in_git_worktree!(app) === nothing
                end
            end
            err = try
                DistSSHRun.pack_ship_tar(app)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("Source path", err.msg)
        end
    end

    @testset "ancestor gitignore files are shipped with a warning" begin
        if Sys.which("git") === nothing
            @test_skip "git is not on PATH"
        else
            _with_tempdir() do tmp
                write(joinpath(tmp, ".gitignore"), "*.pem\n.env\n")
                job = joinpath(tmp, "job")
                mkpath(job)
                write(joinpath(job, "Project.toml"), "name = \"App\"\n")
                write(joinpath(job, "Manifest.toml"), "# lock\n")
                write(joinpath(job, ".gitignore"), "!key.pem\n")
                write(joinpath(job, "key.pem"), "secret\n")
                write(joinpath(job, ".env"), "TOKEN=1\n")
                withenv("GIT_DIR" => nothing, "GIT_WORK_TREE" => nothing, "GIT_INDEX_FILE" => nothing) do
                    run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
                    run(pipeline(`git -C $tmp config user.email "test@example.com"`; stdout = devnull, stderr = devnull))
                    run(pipeline(`git -C $tmp config user.name "Test"`; stdout = devnull, stderr = devnull))
                    run(pipeline(`git -C $tmp add -A`; stdout = devnull, stderr = devnull))
                    run(pipeline(`git -C $tmp -c commit.gpgsign=false commit -q -m init`; stdout = devnull, stderr = devnull))
                end
                text = mktemp() do _, io
                    packed = redirect_stdout(io) do
                        DistSSHRun.pack_ship_tar(job)
                    end
                    try
                        dest = mktempdir()
                        DistSSHRun.Tar.extract(packed.tar_path, dest)
                        @test isfile(joinpath(dest, "key.pem"))
                        @test isfile(joinpath(dest, ".env"))
                    finally
                        rm(packed.tmpd; force = true, recursive = true)
                    end
                    flush(io)
                    seekstart(io)
                    return read(io, String)
                end
                @test occursin("will be shipped", text)
                @test occursin("key.pem", text) || occursin(".env", text)
            end
        end
    end

    @testset "an ancestor-gitignored Manifest is refused" begin
        if Sys.which("git") === nothing
            @test_skip "git is not on PATH"
        else
            _with_tempdir() do tmp
                write(joinpath(tmp, ".gitignore"), "Manifest.toml\n")
                job = joinpath(tmp, "job")
                mkpath(job)
                write(joinpath(job, "Project.toml"), "name = \"App\"\n")
                write(joinpath(job, "Manifest.toml"), "# lock\n")
                withenv("GIT_DIR" => nothing, "GIT_WORK_TREE" => nothing, "GIT_INDEX_FILE" => nothing) do
                    run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
                    run(pipeline(`git -C $tmp config user.email "test@example.com"`; stdout = devnull, stderr = devnull))
                    run(pipeline(`git -C $tmp config user.name "Test"`; stdout = devnull, stderr = devnull))
                    run(pipeline(`git -C $tmp add -A`; stdout = devnull, stderr = devnull))
                    run(pipeline(`git -C $tmp -c commit.gpgsign=false commit -q -m init`; stdout = devnull, stderr = devnull))
                end
                err = try
                    DistSSHRun.pack_ship_tar(job)
                    nothing
                catch e
                    e
                end
                @test err isa ArgumentError
                @test occursin("Manifest Manifest.toml matches a .gitignore above this directory", err.msg)
            end
        end
    end

    @testset "gitignored preferences beside JuliaProject.toml still ship" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "LocalPreferences.toml\n")
            write(joinpath(tmp, "JuliaProject.toml"), "name = \"ShipT\"\n")
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
