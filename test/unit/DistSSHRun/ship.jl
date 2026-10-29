using Test

@testset "run layout" begin
    id = DistSSHRun.allocate_remote_run_id()
    @test occursin(DistSSHRun._RUN_ID_PATTERN, id)
    @test DistSSHRun.validate_run_id(id) == id
    @test_throws ArgumentError DistSSHRun.validate_run_id("not-a-run-id")
    @test DistSSHRun.remote_run_src("~/jobs/app", id) ==
        joinpath("~/jobs/app", "runs", id, "src")
    @test DistSSHRun.validate_expanded_remote_root("/tmp/jobs", "/home/u") == "/tmp/jobs"
    @test_throws ArgumentError DistSSHRun.validate_expanded_remote_root("/", "/home/u")
    @test_throws ArgumentError DistSSHRun.validate_expanded_remote_root("/home/u", "/home/u")
end

@testset "ship tar pack" begin
    Sys.which("git") === nothing && return
    _with_tempdir() do tmp
        run(`git -C $tmp init --quiet`)
        run(`git -C $tmp config user.email t@t.t`)
        run(`git -C $tmp config user.name t`)
        write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
        write(joinpath(tmp, "a.jl"), "1\n")
        mkpath(joinpath(tmp, "sub"))
        write(joinpath(tmp, "sub", "b.txt"), "b\n")
        run(`git -C $tmp add -A`)
        run(`git -C $tmp commit --quiet -m init`)
        packed = DistSSHRun.pack_ship_tar(tmp)
        try
            @test isfile(packed.tar_path)
            @test packed.files >= 3
            @test packed.bytes > 0
            @test packed.hash isa String
            @test length(packed.hash) == 40
            dest = mktempdir()
            DistSSHRun.Tar.extract(packed.tar_path, dest)
            @test isfile(joinpath(dest, "Project.toml"))
            @test isfile(joinpath(dest, "a.jl"))
            @test !isdir(joinpath(dest, ".git"))
        finally
            rm(packed.tmpd; force = true, recursive = true)
        end
        @test_throws ArgumentError DistSSHRun.pack_ship_tar(tmp; ship_max_bytes = 1)
    end
end

@testset "escaping symlink" begin
    Sys.which("git") === nothing && return
    _with_tempdir() do tmp
        run(`git -C $tmp init --quiet`)
        run(`git -C $tmp config user.email t@t.t`)
        run(`git -C $tmp config user.name t`)
        write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
        outside = joinpath(dirname(tmp), "outside-secret")
        write(outside, "secret\n")
        symlink(outside, joinpath(tmp, "link"))
        run(`git -C $tmp add -A`)
        run(`git -C $tmp commit --quiet -m init`)
        @test_throws ArgumentError DistSSHRun.pack_ship_tar(tmp)
        packed = DistSSHRun.pack_ship_tar(tmp; allow_external_symlinks = true)
        rm(packed.tmpd; force = true, recursive = true)
        rm(outside; force = true)
    end
end

@testset "last-ship src is scoped to hosts and remote_root" begin
    DistSSHRun._clear_last_ship!()
    DistSSHRun._LAST_SHIP[] = Dict{String, Any}(
        "src" => "/home/dev/app/runs/id/src",
        "hosts" => String["child-1"],
        "remote_root" => "/home/dev/app",
    )
    DistSSHRun._SHIP_LAYOUT_ACTIVE[] = true
    try
        @test DistSSHRun._work_root_for_hosts(["child-1"], "/home/dev/app") ==
            "/home/dev/app/runs/id/src"
        @test DistSSHRun._work_root_for_hosts(["-other"], "/home/dev/app") ==
            "/home/dev/app"
        @test DistSSHRun._work_root_for_hosts(["child-1"], "/other") !=
            "/home/dev/app/runs/id/src"
        @test DistSSHRun._last_ship_src_for(["child-1"], "/home/dev/app/pkg") === nothing
        wr = DistSSHRun._work_root_for_hosts(["child-1"], "/home/dev/app")
        @test DistSSHRun._rehome_under_work_root(
            "/home/dev/app/pkg", "/home/dev/app", wr,
        ) == "/home/dev/app/runs/id/src/pkg"
    finally
        DistSSHRun._clear_last_ship!()
    end
end

@testset "project work root rehomes workspace member onto shipped src" begin
    DistSSHRun._clear_last_ship!()
    DistSSHRun._LAST_SHIP[] = Dict{String, Any}(
        "src" => "/home/dev/app/runs/id/src",
        "hosts" => String["child-1"],
        "remote_root" => "/home/dev/app",
    )
    DistSSHRun._SHIP_LAYOUT_ACTIVE[] = true
    try
        _with_tempdir() do tmp
            write(
                joinpath(tmp, "Project.toml"),
                "[workspace]\nprojects = [\"pkg\"]\n",
            )
            write(
                joinpath(tmp, "Manifest.toml"),
                "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
            )
            mkpath(joinpath(tmp, "pkg"))
            write(
                joinpath(tmp, "pkg", "Project.toml"),
                "name = \"Pkg\"\nuuid = \"11111111-1111-1111-1111-111111111111\"\n",
            )
            got = DistSSHRun._project_work_root(
                ["child-1"], joinpath(tmp, "pkg");
                cli_override = "/home/dev/app",
            )
            @test got == "/home/dev/app/runs/id/src/pkg"
        end
    finally
        DistSSHRun._clear_last_ship!()
    end
end

@testset "rehome collect path onto work root" begin
    @test DistSSHRun._rehome_under_work_root(
        "/home/dev/app/output",
        "/home/dev/app",
        "/home/dev/app/runs/x/src",
    ) == "/home/dev/app/runs/x/src/output"
    @test DistSSHRun._rehome_under_work_root(
        "/home/dev/app",
        "/home/dev/app",
        "/home/dev/app/runs/x/src",
    ) == "/home/dev/app/runs/x/src"
    @test DistSSHRun._rehome_under_work_root(
        "/tmp/other",
        "/home/dev/app",
        "/home/dev/app/runs/x/src",
    ) == "/tmp/other"
    @test DistSSHRun._rehome_under_work_root(
        "~/app/output",
        "~/app",
        "~/app/runs/x/src",
    ) == "~/app/runs/x/src/output"
    @test DistSSHRun._rehome_under_work_root(
        "/home/dev/app/output",
        "/home/dev/app",
        "/home/dev/app",
    ) == "/home/dev/app/output"
end

@testset "record host and path" begin
    @test DistSSHRun._record_host_alias("mini") == "mini"
    @test DistSSHRun._record_host_alias("user@mini") == "mini"
    _with_tempdir() do proj
        @test DistSSHRun._record_path(joinpath(proj, "out"), proj) == "out"
        @test DistSSHRun._record_path(proj, proj) == "."
        under_tmp = joinpath(tempdir(), "from_hook")
        @test DistSSHRun._record_path(under_tmp, proj) == "from_hook"
    end
    DistSSHRun._clear_last_ship!()
    @test DistSSHRun.last_ship_result() === nothing
    @test DistSSHRun._shipped_src() === nothing
end

@testset "--rsync removed" begin
    err = try
        DistSSHRun.parse_setup_args(["--rsync", "child:h1"])
        error("expected ArgumentError")
    catch e
        e
    end
    @test err isa ArgumentError
    @test err.msg == DistSSHRun.RSYNC_REMOVED_MSG
    err2 = try
        DistSSHRun.parse_go_args(["--rsync", "child:h1:1", "job.jl"])
        error("expected ArgumentError")
    catch e
        e
    end
    @test err2 isa ArgumentError
    @test err2.msg == DistSSHRun.RSYNC_REMOVED_MSG
    err3 = try
        DistSSHRun.parse_drive_args(["--rsync", "s.jl"])
        error("expected ArgumentError")
    catch e
        e
    end
    @test err3 isa ArgumentError
    @test err3.msg == DistSSHRun.RSYNC_REMOVED_MSG
end

@testset "openrsync warn uses the rsync collect will run" begin
    DistSSHRun._OPENRSYNC_WARNED[] = false
    try
        _with_tempdir() do tmp
            withenv(_fake_setup_remote_env(tmp)...) do
                @test_logs DistSSHRun.warn_openrsync_once()
                @test DistSSHRun._OPENRSYNC_WARNED[] == false
            end
        end
    finally
        DistSSHRun._OPENRSYNC_WARNED[] = false
    end
end

@testset "rsync_send_list is the ship set" begin
    Sys.which("git") === nothing && return
    _with_tempdir() do tmp
        run(`git -C $tmp init --quiet`)
        run(`git -C $tmp config user.email t@t.t`)
        run(`git -C $tmp config user.name t`)
        write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
        write(joinpath(tmp, "tracked.jl"), "1\n")
        run(`git -C $tmp add -A`)
        run(`git -C $tmp commit --quiet -m init`)
        env = DistSSHRun.resolve_pkg_env(tmp)
        listed = DistSSHRun.rsync_send_list(tmp, env)
        @test listed isa Vector
        @test "tracked.jl" in listed
        @test !any(startswith(r, ".git") for r in listed)
    end
end
