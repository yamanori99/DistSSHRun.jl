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

@testset "gitignored project preferences ship" begin
    Sys.which("git") === nothing && return
    _with_tempdir() do tmp
        run(`git -C $tmp init --quiet`)
        run(`git -C $tmp config user.email t@t.t`)
        run(`git -C $tmp config user.name t`)
        write(joinpath(tmp, ".gitignore"), "LocalPreferences.toml\nJuliaLocalPreferences.toml\n")
        write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
        write(joinpath(tmp, "LocalPreferences.toml"), "[ShipT]\nx = 1\n")
        write(joinpath(tmp, "JuliaLocalPreferences.toml"), "[ShipT]\ny = 2\n")
        run(`git -C $tmp add -A`)
        run(`git -C $tmp commit --quiet -m init`)
        listed = DistSSHRun.rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
        @test listed isa Vector
        @test "LocalPreferences.toml" ∉ listed
        packed = DistSSHRun.pack_ship_tar(tmp)
        try
            dest = mktempdir()
            DistSSHRun.Tar.extract(packed.tar_path, dest)
            @test isfile(joinpath(dest, "LocalPreferences.toml"))
            @test isfile(joinpath(dest, "JuliaLocalPreferences.toml"))
        finally
            rm(packed.tmpd; force = true, recursive = true)
        end
    end
end

@testset "symlinked project preference is refused" begin
    Sys.which("git") === nothing && return
    _with_tempdir() do tmp
        run(`git -C $tmp init --quiet`)
        run(`git -C $tmp config user.email t@t.t`)
        run(`git -C $tmp config user.name t`)
        write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
        write(joinpath(tmp, "prefs.toml"), "[ShipT]\nx = 1\n")
        symlink("prefs.toml", joinpath(tmp, "LocalPreferences.toml"))
        run(`git -C $tmp add -A`)
        run(`git -C $tmp commit --quiet -m init`)
        err = try
            DistSSHRun.pack_ship_tar(tmp)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("symlinked project preference", err.msg)
        @test occursin("LocalPreferences.toml", err.msg)
    end
    _with_tempdir() do tmp
        run(`git -C $tmp init --quiet`)
        run(`git -C $tmp config user.email t@t.t`)
        run(`git -C $tmp config user.name t`)
        write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
        symlink("missing.toml", joinpath(tmp, "LocalPreferences.toml"))
        run(`git -C $tmp add -A`)
        run(`git -C $tmp commit --quiet -m init`)
        err = try
            DistSSHRun.pack_ship_tar(tmp)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("LocalPreferences.toml", err.msg)
    end
    _with_tempdir() do tmp
        run(`git -C $tmp init --quiet`)
        run(`git -C $tmp config user.email t@t.t`)
        run(`git -C $tmp config user.name t`)
        write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
        mkpath(joinpath(tmp, "prefsdir"))
        symlink("prefsdir", joinpath(tmp, "JuliaLocalPreferences.toml"))
        run(`git -C $tmp add -A`)
        run(`git -C $tmp commit --quiet -m init`)
        err = try
            DistSSHRun.pack_ship_tar(tmp)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("JuliaLocalPreferences.toml", err.msg)
    end
    _with_tempdir() do tmp
        run(`git -C $tmp init --quiet`)
        run(`git -C $tmp config user.email t@t.t`)
        run(`git -C $tmp config user.name t`)
        write(joinpath(tmp, ".gitignore"), "LocalPreferences.toml\n")
        write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
        symlink("missing.toml", joinpath(tmp, "LocalPreferences.toml"))
        run(`git -C $tmp add -A`)
        run(`git -C $tmp commit --quiet -m init`)
        err = try
            DistSSHRun.pack_ship_tar(tmp)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("LocalPreferences.toml", err.msg)
    end
end

@testset "depot preferences refuse ship" begin
    empty = joinpath(mktempdir(), "empty.toml")
    write(empty, "")
    @test DistSSHRun._refuse_unshipped_depot_prefs!([empty]) === nothing
    hit = joinpath(mktempdir(), "Overrides.toml")
    write(hit, "Example = \"/tmp/example\"\n")
    err = try
        DistSSHRun._refuse_unshipped_depot_prefs!([hit])
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("not shipped", sprint(showerror, err))
    @test occursin("sha256=", sprint(showerror, err))
end

@testset "declared inputs stay out of the ship" begin
    Sys.which("git") === nothing && return
    _with_tempdir() do tmp
        run(`git -C $tmp init --quiet`)
        run(`git -C $tmp config user.email t@t.t`)
        run(`git -C $tmp config user.name t`)
        write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
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
        run(`git -C $tmp add -A`)
        run(`git -C $tmp commit --quiet -m init`)
        packed = DistSSHRun.pack_ship_tar(tmp)
        try
            dest = mktempdir()
            DistSSHRun.Tar.extract(packed.tar_path, dest)
            @test !isfile(joinpath(dest, "data", "big.bin"))
            @test isfile(joinpath(dest, "Project.toml"))
        finally
            rm(packed.tmpd; force = true, recursive = true)
        end
        probe = DistSSHRun._remote_input_probe_sh("/remote/data", false)
        @test occursin("stat", probe)
        @test occursin("files=%s", probe)
        @test occursin("find . -type f", probe)
        @test occursin("input filename contains a newline", probe)
        hashed = DistSSHRun._remote_input_probe_sh("/remote/data", true)
        @test occursin("sha256sum", hashed)
        @test occursin("cd ", hashed)
        @test occursin("\${_f#./}", hashed)
        @test occursin("|| exit 1", hashed)
        run_dir = mktempdir()
        DistSSHRun._write_input_manifest!(
            run_dir,
            [Dict{String, Any}("name" => "big", "path" => "data", "host" => "h", "kind" => "stat", "value" => "1 2")],
        )
        @test isfile(joinpath(run_dir, "inputs.toml"))
        @test !isfile(joinpath(tmp, "inputs.toml"))
        withenv("DISTSSHKIT_RUN_DIR" => nothing) do
            err = try
                DistSSHRun.ship_project_to_hosts!(
                    ["host.test"], tmp, "/remote/app"; confirm = false, report = false,
                )
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("DISTSSHKIT_RUN_DIR", sprint(showerror, err))
        end
    end
end

@testset "declared input paths and probes" begin
    _with_tempdir() do tmp
        mkpath(joinpath(tmp, ".distsshkit"))
        write(
            joinpath(tmp, ".distsshkit", "inputs.toml"),
            """
            [[inputs]]
            name = "big"
            path = "data/"
            """,
        )
        inputs = DistSSHRun._load_ship_inputs(tmp)
        @test length(inputs) == 1
        @test inputs[1].path == "data"
        @test DistSSHRun._ship_input_covers("data", inputs)
        @test DistSSHRun._ship_input_covers("data/big.bin", inputs)
        @test !DistSSHRun._ship_input_covers("database", inputs)
        write(
            joinpath(tmp, ".distsshkit", "inputs.toml"),
            """
            [[inputs]]
            name = "bad"
            path = "data/../secret"
            """,
        )
        @test_throws ArgumentError DistSSHRun._load_ship_inputs(tmp)
        write(
            joinpath(tmp, ".distsshkit", "inputs.toml"),
            """
            [[inputs]]
            name = "bad"
            path = "data/a\\nb"
            """,
        )
        @test_throws ArgumentError DistSSHRun._load_ship_inputs(tmp)
    end
    root = mktempdir()
    other = mktempdir()
    link = joinpath(dirname(root), "declared-input-link-" * basename(root))
    try
        mkpath(joinpath(root, "sub"))
        write(joinpath(root, "sub", "a.txt"), "hi\n")
        mkpath(joinpath(other, "sub"))
        write(joinpath(other, "sub", "a.txt"), "hi\n")
        symlink(root, link)
        hashed = strip(read(`sh -c $(DistSSHRun._remote_input_probe_sh(root, true))`, String))
        @test occursin(r"^[0-9a-fA-F]{64}$", hashed)
        @test hashed == strip(read(`sh -c $(DistSSHRun._remote_input_probe_sh(other, true))`, String))
        @test hashed == strip(read(`sh -c $(DistSSHRun._remote_input_probe_sh(link, true))`, String))
        write(joinpath(root, "sub", "a.txt"), "changed\n")
        @test hashed != strip(read(`sh -c $(DistSSHRun._remote_input_probe_sh(root, true))`, String))
        write(joinpath(root, "sub", "a.txt"), "hi\n")
        symlink("a.txt", joinpath(root, "sub", "via"))
        with_link = strip(read(`sh -c $(DistSSHRun._remote_input_probe_sh(root, true))`, String))
        @test with_link != hashed
        stat_line = strip(read(`sh -c $(DistSSHRun._remote_input_probe_sh(other, false))`, String))
        @test startswith(stat_line, "files=1 bytes=")
        @test occursin(r"digest=[0-9a-fA-F]{64}$", stat_line)
        missing = DistSSHRun._remote_input_probe_sh(joinpath(root, "nope"), true)
        proc = run(pipeline(`sh -c $missing`; stdout = devnull, stderr = devnull); wait = false)
        wait(proc)
        @test proc.exitcode == 2
        write(joinpath(root, "sub", "a\nb.txt"), "x\n")
        nl_probe = DistSSHRun._remote_input_probe_sh(root, true)
        nl_out = IOBuffer()
        nl_proc = run(pipeline(`sh -c $nl_probe`; stdout = nl_out, stderr = devnull); wait = false)
        wait(nl_proc)
        @test nl_proc.exitcode == 2
        @test occursin("newline", String(take!(nl_out)))
    finally
        rm(link; force = true)
        rm(root; force = true, recursive = true)
        rm(other; force = true, recursive = true)
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

@testset "rsync_send_list is the git send list" begin
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
