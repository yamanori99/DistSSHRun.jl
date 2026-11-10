using TOML
using Test
using DistSSHShip

function _tmp(f)
    dir = mktempdir()
    try
        return f(dir)
    finally
        rm(dir; force = true, recursive = true)
    end
end

function _project!(dir; name = "App", extra = "")
    write(joinpath(dir, "Project.toml"), "name = \"$name\"\n$extra")
    write(joinpath(dir, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
    return dir
end

function _extract(snapshot)
    dest = mktempdir()
    DistSSHShip.Tar.extract(snapshot.tar_path, dest)
    return dest
end

function _local_extract_verified!(
        dest::AbstractString,
        tar_path::AbstractString,
        expect_hash::AbstractString;
        allow_external_symlinks::Bool = false,
    )
    open(tar_path) do io
        DistSSHShip.Tar.extract(io, dest)
    end
    DistSSHShip.assert_extracted_tree_contained!(
        dest; allow_external_symlinks = allow_external_symlinks,
    )
    buf = IOBuffer()
    DistSSHShip.Tar.create(dest, buf)
    seekstart(buf)
    got = String(
        DistSSHShip.Tar.tree_hash(buf; algorithm = "git-sha1", skip_empty = true),
    )
    got == expect_hash ||
        throw(ArgumentError("content_tree_hash mismatch: " * got * " != " * expect_hash))
    return nothing
end

function _minimal_snapshot(project_rel::String)::DistSSHShip.ShipPack
    bundle = mktempdir()
    tar_path = joinpath(bundle, "snap.tar")
    src = joinpath(bundle, "src")
    mkdir(src)
    _project!(src)
    open(tar_path, "w") do io
        DistSSHShip.Tar.create(src, io)
    end
    hash = String(DistSSHShip.Tar.tree_hash(tar_path; algorithm = "git-sha1", skip_empty = true))
    bytes = filesize(tar_path)
    files = 2
    return DistSSHShip.ShipPack(
        bundle, tar_path, hash, bytes, files, src, src, project_rel,
        String[], String[],
    )
end

@testset "DistSSHShip" verbose = true begin
    @testset "project root" begin
        _tmp() do dir
            _project!(dir)
            found = DistSSHShip.resolve_ship_project(dir)
            @test found.project_dir == abspath(dir)
            @test endswith(found.project_file, "Project.toml")
            file = joinpath(dir, "Project.toml")
            @test DistSSHShip.resolve_ship_project(file).project_file == abspath(file)
            child = joinpath(dir, "sub")
            mkdir(child)
            @test_throws ArgumentError DistSSHShip.resolve_ship_project("."; cwd = child)
            @test DistSSHShip.resolve_ship_project(""; cwd = child).project_file == abspath(file)
            @test DistSSHShip.resolve_ship_project("@."; cwd = child).project_file == abspath(file)
            write(joinpath(dir, "JuliaProject.toml"), "name = \"JuliaWins\"\n")
            @test endswith(DistSSHShip.resolve_ship_project(dir).project_file, "JuliaProject.toml")
            script = joinpath(dir, "job.jl")
            write(script, "1\n")
            @test DistSSHShip.resolve_ship_project("@script"; script = script, cwd = "/tmp").project_dir ==
                abspath(dir)
            nested = joinpath(child, "job.jl")
            write(nested, "1\n")
            @test DistSSHShip.resolve_ship_project(
                "@script/.."; script = nested, cwd = "/tmp",
            ).project_dir == abspath(dir)
        end
        _tmp() do empty
            @test_throws ArgumentError DistSSHShip.resolve_ship_project("@."; cwd = empty)
            @test_throws ArgumentError DistSSHShip.resolve_ship_project(joinpath(empty, "missing"))
            @test_throws ArgumentError DistSSHShip.resolve_ship_project(empty)
        end
        for spec in ("@temp", "@stdlib", "@v1.13", "@name")
            @test_throws ArgumentError DistSSHShip.resolve_ship_project(spec; cwd = "/tmp")
        end
        @test_throws ArgumentError DistSSHShip.resolve_ship_project("@script"; cwd = "/tmp")
    end

    @testset "file selection" begin
        _tmp() do dir
            _project!(dir)
            write(joinpath(dir, ".gitignore"), "*.log\nsecret.jl\n")
            write(joinpath(dir, "keep.jl"), "1\n")
            write(joinpath(dir, "skip.log"), "no\n")
            write(joinpath(dir, "secret.jl"), "no\n")
            listed = DistSSHShip.selected_paths(dir)
            @test "keep.jl" in listed
            @test "Project.toml" in listed
            @test !("skip.log" in listed)
            @test !("secret.jl" in listed)
            @test DistSSHShip.pack_paths(dir) == listed
            write(joinpath(dir, "a\nb.jl"), "x\n")
            @test_throws ArgumentError DistSSHShip.selected_paths(dir)
            @test_throws ArgumentError DistSSHShip.pack_paths(dir)
        end
    end

    @testset "pack_paths matches a flat snapshot tar" begin
        _tmp() do dir
            _project!(dir)
            write(joinpath(dir, "keep.jl"), "1\n")
            listed = DistSSHShip.pack_paths(dir)
            snap = DistSSHShip.pack_tree(dir)
            try
                tree = _extract(snap)
                on_disk = String[]
                for (root, _, files) in walkdir(tree)
                    for f in files
                        rel = replace(relpath(joinpath(root, f), tree), '\\' => '/')
                        push!(on_disk, rel)
                    end
                end
                sort!(on_disk)
                @test on_disk == listed
                @test snap.content_tree_hash == String(
                    DistSSHShip.Tar.tree_hash(snap.tar_path; algorithm = "git-sha1", skip_empty = true),
                )
            finally
                rm(snap.directory; force = true, recursive = true)
            end
        end
    end

    @testset "gitignored manifest warns and is omitted" begin
        _tmp() do dir
            _project!(dir)
            write(joinpath(dir, ".gitignore"), "Manifest.toml\n")
            text = mktemp() do _, io
                snap = redirect_stdout(io) do
                    DistSSHShip.pack_tree(dir)
                end
                try
                    dest = _extract(snap)
                    try
                        @test !isfile(joinpath(dest, "Manifest.toml"))
                        @test isfile(joinpath(dest, "Project.toml"))
                    finally
                        rm(dest; force = true, recursive = true)
                    end
                finally
                    rm(snap.directory; force = true, recursive = true)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test occursin("Manifest.toml", text)
            @test occursin("will not be shipped", text)
        end
    end

    @testset "path dependencies keep their relative layout" begin
        _tmp() do root
            app = joinpath(root, "app")
            bar = joinpath(root, "shared", "Bar")
            mkpath(app)
            mkpath(joinpath(bar, "src"))
            write(joinpath(app, "Project.toml"), "name = \"App\"\n")
            write(
                joinpath(app, "Manifest.toml"),
                """
                julia_version = "1.13.0"
                manifest_format = "2.0"
                [[deps.Bar]]
                path = "../shared/Bar"
                uuid = "00000000-0000-0000-0000-000000000001"
                version = "0.1.0"
                """,
            )
            write(joinpath(bar, "Project.toml"), "name = \"Bar\"\n")
            write(joinpath(bar, "src", "Bar.jl"), "module Bar end\n")
            write(joinpath(bar, ".gitignore"), "*.log\n")
            write(joinpath(bar, "skip.log"), "no\n")
            snap = DistSSHShip.pack_tree(app)
            try
                @test snap.project_rel == "app"
                dest = _extract(snap)
                try
                    @test isfile(joinpath(dest, "app", "Project.toml"))
                    @test isfile(joinpath(dest, "app", "Manifest.toml"))
                    @test isfile(joinpath(dest, "shared", "Bar", "src", "Bar.jl"))
                    @test !isfile(joinpath(dest, "shared", "Bar", "skip.log"))
                finally
                    rm(dest; force = true, recursive = true)
                end
            finally
                rm(snap.directory; force = true, recursive = true)
            end
        end
    end

    @testset "a path dependency with no selected files does not break snapshot" begin
        _tmp() do root
            app = joinpath(root, "app")
            dep = joinpath(root, "dep")
            mkpath(app)
            mkpath(dep)
            write(joinpath(app, "keep.jl"), "1\n")
            write(joinpath(app, "Project.toml"), "name = \"App\"\n")
            write(
                joinpath(app, "Manifest.toml"),
                """
                julia_version = "1.13.0"
                manifest_format = "2.0"
                [[deps.Dep]]
                path = "../dep"
                uuid = "00000000-0000-0000-0000-000000000002"
                version = "0.1.0"
                """,
            )
            write(joinpath(dep, ".gitignore"), "*\n")
            write(joinpath(dep, "note.txt"), "ignored\n")
            @test_throws ArgumentError DistSSHShip.selected_paths(dep)
            snap = DistSSHShip.pack_tree(app)
            try
                dest = _extract(snap)
                try
                    @test isfile(joinpath(dest, "app", "keep.jl"))
                finally
                    rm(dest; force = true, recursive = true)
                end
            finally
                rm(snap.directory; force = true, recursive = true)
            end
        end
    end

    @testset "a parent gitignore does not drop a declared path dependency" begin
        _tmp() do dir
            foo = joinpath(dir, "vendor", "Foo")
            mkpath(joinpath(foo, "src"))
            write(
                joinpath(dir, "Project.toml"),
                """
                name = "App"
                [sources]
                Foo = {path = "vendor/Foo"}
                """,
            )
            write(joinpath(dir, "Manifest.toml"), "# lock\n")
            write(joinpath(dir, ".gitignore"), "vendor/\n")
            write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(foo, "src", "Foo.jl"), "module Foo end\n")
            snap = DistSSHShip.pack_tree(dir)
            try
                dest = _extract(snap)
                try
                    @test isfile(joinpath(dest, "vendor", "Foo", "src", "Foo.jl"))
                finally
                    rm(dest; force = true, recursive = true)
                end
            finally
                rm(snap.directory; force = true, recursive = true)
            end
        end
    end

    @testset "absolute, home, and root path dependencies are refused" begin
        _tmp() do dir
            foo = joinpath(dir, "Foo")
            mkpath(foo)
            write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
            absfoo = replace(foo, '\\' => '/')
            write(
                joinpath(dir, "Project.toml"),
                """
                name = "App"
                [sources]
                Foo = {path = "$absfoo"}
                """,
            )
            write(joinpath(dir, "Manifest.toml"), "# lock\n")
            err = try
                DistSSHShip.pack_tree(dir)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("absolute", err.msg)
        end
        home = homedir()
        a = mktempdir(home)
        b = mktempdir(home)
        try
            _project!(a)
            _project!(b; name = "Dep")
            write(
                joinpath(a, "Project.toml"),
                """
                name = "App"
                [sources]
                Dep = {path = "$(relpath(b, a))"}
                """,
            )
            err = try
                DistSSHShip.pack_tree(a)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("HOME", err.msg)
        finally
            rm(a; force = true, recursive = true)
            rm(b; force = true, recursive = true)
        end
    end

    @testset "workspace member ships the workspace files, not siblings" begin
        _tmp() do lab
            member = joinpath(lab, "member")
            other = joinpath(lab, "other")
            mkpath(member)
            mkpath(other)
            write(
                joinpath(lab, "Project.toml"),
                """
                name = "Lab"
                [workspace]
                projects = ["member", "other"]
                """,
            )
            write(
                joinpath(lab, "Manifest.toml"),
                """
                julia_version = "1.13.0"
                manifest_format = "2.0"
                [[deps.Other]]
                path = "other"
                uuid = "00000000-0000-0000-0000-000000000002"
                version = "0.1.0"
                """,
            )
            write(
                joinpath(member, "Project.toml"),
                """
                name = "Run1"
                [sources]
                Lab = {path = ".."}
                """,
            )
            write(joinpath(other, "Project.toml"), "name = \"Other\"\n")
            write(joinpath(other, "secret.jl"), "no\n")
            snap = DistSSHShip.pack_tree(member)
            try
                @test snap.project_rel == "member"
                dest = _extract(snap)
                try
                    @test isfile(joinpath(dest, "member", "Project.toml"))
                    @test isfile(joinpath(dest, "Project.toml"))
                    @test isfile(joinpath(dest, "Manifest.toml"))
                    @test !isfile(joinpath(dest, "other", "secret.jl"))
                finally
                    rm(dest; force = true, recursive = true)
                end
            finally
                rm(snap.directory; force = true, recursive = true)
            end
        end
    end

    @testset "one external file" begin
        _tmp() do parent
            dir = joinpath(parent, "proj")
            mkdir(dir)
            _project!(dir)
            outside = joinpath(parent, "helper.jl")
            write(outside, "helper = 1\n")
            link = joinpath(parent, "helper-link.jl")
            symlink(outside, link)
            snap = DistSSHShip.pack_tree(dir; extra_files = String[abspath(link)])
            try
                dest = _extract(snap)
                try
                    shipped = joinpath(dest, "_distsshrun_external", "helper-link.jl")
                    @test isfile(shipped)
                    @test !islink(shipped)
                    @test read(shipped, String) == "helper = 1\n"
                    @test snap.extra_rels == ["_distsshrun_external/helper-link.jl"]
                finally
                    rm(dest; force = true, recursive = true)
                end
            finally
                rm(snap.directory; force = true, recursive = true)
            end
            link2 = joinpath(parent, "double.jl")
            symlink(link, link2)
            @test_throws ArgumentError DistSSHShip.pack_tree(dir; extra_files = String[link2])
            rm(link2; force = true)
            @test_throws ArgumentError DistSSHShip.pack_tree(
                dir; extra_files = String[abspath(outside), abspath(outside)],
            )
            mkdir(joinpath(dir, "_distsshrun_external"))
            @test_throws ArgumentError DistSSHShip.pack_tree(dir; extra_files = String[abspath(outside)])
        end
    end

    @testset "content hash ignores the local absolute prefix" begin
        function tree!(root)
            app = joinpath(root, "app")
            mkpath(app)
            write(joinpath(app, "Project.toml"), "name = \"App\"\n")
            write(joinpath(app, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
            write(joinpath(app, "a.jl"), "println(1)\n")
            return app
        end
        h1 = _tmp() do a
            snap = DistSSHShip.pack_tree(tree!(a))
            h = snap.content_tree_hash
            rm(snap.directory; force = true, recursive = true)
            return h
        end
        h2 = _tmp() do b
            snap = DistSSHShip.pack_tree(tree!(b))
            h = snap.content_tree_hash
            rm(snap.directory; force = true, recursive = true)
            return h
        end
        @test h1 == h2
        @test !isempty(h1)
        _tmp() do root
            snap = DistSSHShip.pack_tree(tree!(root))
            try
                dest = _extract(snap)
                try
                    buf = IOBuffer()
                    DistSSHShip.Tar.create(dest, buf)
                    seekstart(buf)
                    got = String(
                        DistSSHShip.Tar.tree_hash(buf; algorithm = "git-sha1", skip_empty = true),
                    )
                    @test got == snap.content_tree_hash
                finally
                    rm(dest; force = true, recursive = true)
                end
            finally
                rm(snap.directory; force = true, recursive = true)
            end
        end
    end

    @testset "a symlink spelling of the project keeps the relative layout" begin
        _tmp() do real
            app = joinpath(real, "app")
            bar = joinpath(real, "shared", "Bar")
            mkpath(app)
            mkpath(joinpath(bar, "src"))
            write(
                joinpath(app, "Manifest.toml"),
                """
                julia_version = "1.13.0"
                manifest_format = "2.0"
                [[deps.Bar]]
                path = "../shared/Bar"
                uuid = "00000000-0000-0000-0000-000000000001"
                version = "0.1.0"
                """,
            )
            write(joinpath(app, "Project.toml"), "name = \"App\"\n")
            write(joinpath(bar, "Project.toml"), "name = \"Bar\"\n")
            write(joinpath(bar, "src", "Bar.jl"), "module Bar end\n")
            link_parent = mktempdir()
            try
                via = joinpath(link_parent, "via")
                symlink(real, via)
                snap = DistSSHShip.pack_tree(joinpath(via, "app"))
                try
                    @test snap.project_rel == "app"
                    dest = _extract(snap)
                    try
                        @test isfile(joinpath(dest, "app", "Project.toml"))
                        @test isfile(joinpath(dest, "shared", "Bar", "src", "Bar.jl"))
                    finally
                        rm(dest; force = true, recursive = true)
                    end
                finally
                    rm(snap.directory; force = true, recursive = true)
                end
            finally
                rm(link_parent; force = true, recursive = true)
            end
        end
    end

    @testset "extracted symlink containment" begin
        _tmp() do dir
            inner = joinpath(dir, "tree")
            mkdir(inner)
            write(joinpath(inner, "a.txt"), "a\n")
            symlink("/etc/passwd", joinpath(inner, "out"))
            @test_throws ArgumentError DistSSHShip.assert_extracted_tree_contained!(inner)
            @test DistSSHShip.assert_extracted_tree_contained!(
                inner; allow_external_symlinks = true,
            ) === nothing
        end
    end

    @testset "ship record format" begin
        _tmp() do dir
            _project!(dir)
            snap = DistSSHShip.pack_tree(dir)
            try
                prog = DistSSHShip.build_ship_record(snap; complete = false)
                @test prog["schema"] == 1
                @test prog["complete"] === false
                @test prog["content_tree_hash"] == snap.content_tree_hash
                @test startswith(String(prog["writer"]), "DistSSHShip")
                done = DistSSHShip.build_ship_record(snap; complete = true)
                @test done["complete"] === true
                @test DistSSHShip.ship_record_status(done) == :complete
                @test DistSSHShip.ship_record_status(prog) == :in_progress
                path = DistSSHShip.ship_record_logical_path("/stage/tree")
                @test path == "/stage/tree/.distssh/ship.toml"
                path2 = DistSSHShip.ship_record_logical_path("~/q/stage")
                @test path2 == "~/q/stage/.distssh/ship.toml"
            finally
                rm(snap.directory; force = true, recursive = true)
            end
        end
        bad = Dict(
            "schema" => 1,
            "writer" => "Other",
            "complete" => true,
            "algorithm" => "git-sha1",
            "content_tree_hash" => "a"^40,
        )
        @test DistSSHShip.ship_record_status(bad) == :invalid
    end

    @testset "ship per-host step order" begin
        snap = _minimal_snapshot(".")
        try
            order = Symbol[]
            hooks = DistSSHShip._ShipHooks(
                (_, _) -> push!(order, :prepare),
                (_, _, _, _; _...) -> push!(order, :extract),
                (_, _, _) -> push!(order, :record),
            )
            DistSSHShip._ship_one_host!(
                "host.test", "/stage/tree", snap, false, true; hooks = hooks,
            )
            @test order == [:prepare, :extract, :record]
            empty!(order)
            DistSSHShip._ship_one_host!(
                "host.test", "/stage/tree", snap, false, false; hooks = hooks,
            )
            @test order == [:prepare, :extract]
        finally
            rm(snap.directory; force = true, recursive = true)
        end
    end

    @testset "ship record ordering vs tar extract" begin
        _tmp() do dir
            _project!(dir)
            snap = DistSSHShip.pack_tree(dir)
            try
                dest = mktempdir()
                try
                    mkpath(joinpath(dest, ".distssh"))
                    write(joinpath(dest, ".distssh", "ship.toml"), "complete = false\n")
                    @test_throws ErrorException DistSSHShip.Tar.extract(snap.tar_path, dest)
                    dest2 = mktempdir()
                    try
                        _local_extract_verified!(
                            dest2, snap.tar_path, snap.content_tree_hash,
                        )
                        rec = DistSSHShip.build_ship_record(snap; complete = true)
                        @test rec["complete"] === true
                        mkpath(joinpath(dest2, ".distssh"))
                        write(
                            joinpath(dest2, ".distssh", "ship.toml"),
                            sprint(TOML.print, rec),
                        )
                        buf = IOBuffer()
                        DistSSHShip.Tar.create(dest2, buf)
                        seekstart(buf)
                        got = String(
                            DistSSHShip.Tar.tree_hash(
                                buf; algorithm = "git-sha1", skip_empty = true,
                            ),
                        )
                        @test got != snap.content_tree_hash
                    finally
                        rm(dest2; force = true, recursive = true)
                    end
                finally
                    rm(dest; force = true, recursive = true)
                end
            finally
                rm(snap.directory; force = true, recursive = true)
            end
        end
    end

    @testset "project_rel in ship record" begin
        tricky = "my app/x\"'\$`part"
        snap = _minimal_snapshot(tricky)
        try
            rec = DistSSHShip.build_ship_record(snap; complete = true)
            @test rec["project_rel"] == tricky
            body = sprint(TOML.print, rec)
            parsed = TOML.parse(body)
            @test parsed["project_rel"] == tricky
            @test DistSSHShip.ship_record_status(rec) == :complete
            for bad in ("", "/", "a//b", "..", "a/../b", "a\nb")
                bad_snap = _minimal_snapshot(bad)
                try
                    @test_throws ArgumentError DistSSHShip.build_ship_record(bad_snap)
                finally
                    rm(bad_snap.directory; force = true, recursive = true)
                end
            end
        finally
            rm(snap.directory; force = true, recursive = true)
        end
    end
end
