using Test
using TOML

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

@testset "ship-tree refuses a repeated host" begin
    err = try
        DistSSHRun.ship_project_to_hosts!(["h", "h"], "/tmp", "/remote/app")
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("hosts must be unique", sprint(showerror, err))
end

@testset "remote run leaf stamp is DistSSHRun-owned" begin
    stamp = DistSSHRun._ship_run_leaf_stamp_toml()
    @test occursin("schema = 1", stamp)
    @test occursin("kind = \"ship\"", stamp)
    @test occursin("writer = \"DistSSHRun ", stamp)
    @test !occursin("complete = true", stamp)
    raw = TOML.parse(stamp)
    @test DistSSHRun._kit_run_toml_owned(raw)
    complete = DistSSHRun._ship_run_leaf_complete_toml("deadbeef")
    @test occursin("complete = true", complete)
    @test DistSSHRun._kit_run_toml_owned(TOML.parse(complete))
    @test !DistSSHRun._kit_run_toml_owned(
        Dict("schema" => 1, "writer" => "Other 1.0", "kind" => "ship"),
    )
    @test !DistSSHRun._kit_run_toml_owned(
        Dict("schema" => 1, "writer" => "DistSSHRun 1.0", "kind" => "other"),
    )
    sh = DistSSHRun._remote_run_leaf_stamp_sh("/work/app/runs/20260101T000000Z-abcd")
    @test occursin("/work/app/runs/20260101T000000Z-abcd/run.toml", sh)
    @test occursin("kind = \"ship\"", sh)
    csh = DistSSHRun._remote_run_leaf_complete_sh(
        "/work/app/runs/20260101T000000Z-abcd", "deadbeef",
    )
    @test occursin("complete = true", csh)
end

@testset "remote run leaf still validates an existing root" begin
    sh = DistSSHRun._remote_run_leaf_script("/work/app", "20260101T000000Z-abcd")
    @test occursin("remote_root does not exist", sh)
    @test occursin("ls -ldL", sh)
    @test occursin("could not read remote_root mode", sh)
    @test occursin("stat -L -c", sh)
    @test occursin("group or world writable", sh)
    @test occursin("owner", sh)
    @test occursin("mkdir '/work/app/runs' || [ -d '/work/app/runs' ]", sh)
    @test !occursin("mkdir -p", sh)
    @test occursin("/work/app/runs/20260101T000000Z-abcd/src", sh)
    @test occursin("/work/app/runs/20260101T000000Z-abcd/out", sh)
    @test occursin("refusing symlinked out dir", sh)
    @test occursin("could not inspect out dir", sh)
    @test occursin("out dir is not empty", sh)
    @test occursin("mkdir '/work/app/runs/20260101T000000Z-abcd/out'", sh)
    parent = mktempdir()
    try
        root = joinpath(parent, "app")
        mkpath(root)
        chmod(root, 0o755)
        script = DistSSHRun._remote_run_leaf_script(root, "20260101T000000Z-abcd")
        run(`sh -c $script`)
        out = joinpath(root, "runs", "20260101T000000Z-abcd", "out")
        @test isdir(out)
        @test isempty(readdir(out))
    finally
        rm(parent; force = true, recursive = true)
    end
end

@testset "ship ensure creates safe remote roots" begin
    abs_sh = DistSSHRun._remote_root_create_script("/tmp/jobs/app"; report = true)
    @test occursin("__DSR_ENSURE_REMOTE_ROOT__", abs_sh)
    @test occursin("CREATED", abs_sh)
    @test occursin("EXISTED", abs_sh)
    @test occursin("mkdir -m 700 ", abs_sh)
    @test !occursin("mkdir -p", abs_sh)
    home = mktempdir()
    try
        root = joinpath(home, "Parent", "Repo")
        under = DistSSHRun._remote_root_ensure_under_home_script(root, home)
        @test occursin("__DSR_ENSURE_REMOTE_ROOT__", under)
        @test occursin("remote_root is not under home", under)
        out = read(`sh -c $under`, String)
        @test isdir(root)
        @test (filemode(root) & 0o022) == 0
        @test occursin("CREATED", out)
        again = read(`sh -c $under`, String)
        @test occursin("EXISTED", again)
        @test (filemode(root) & 0o022) == 0
        missing_parent = joinpath(home, "nope", "leaf")
        abs_missing = DistSSHRun._remote_root_create_script(missing_parent; report = true)
        bad = run(pipeline(`sh -c $abs_missing`; stdout = devnull, stderr = devnull); wait = false)
        wait(bad)
        @test bad.exitcode == 2
        @test !isdir(missing_parent)
        parent = joinpath(home, "absparent")
        mkpath(parent)
        leaf = joinpath(parent, "leaf")
        abs_ok = DistSSHRun._remote_root_create_script(leaf; report = true)
        @test occursin("CREATED", read(`sh -c $abs_ok`, String))
        @test isdir(leaf)
        @test (filemode(leaf) & 0o022) == 0
        chmod(leaf, 0o755)
        @test occursin("EXISTED", read(`sh -c $abs_ok`, String))
        @test (filemode(leaf) & 0o777) == 0o755
        chmod(leaf, 0o775)
        loose = run(pipeline(`sh -c $abs_ok`; stdout = devnull, stderr = devnull); wait = false)
        wait(loose)
        @test loose.exitcode == 2
        chmod(leaf, 0o755)
        file_path = joinpath(parent, "fileleaf")
        write(file_path, "x")
        file_sh = DistSSHRun._remote_root_create_script(file_path; report = true)
        file_bad = run(pipeline(`sh -c $file_sh`; stdout = devnull, stderr = devnull); wait = false)
        wait(file_bad)
        @test file_bad.exitcode == 2
        if !Sys.iswindows()
            link_parent = joinpath(home, "linkparent")
            mkpath(link_parent)
            real_leaf = joinpath(link_parent, "real")
            mkpath(real_leaf)
            link_leaf = joinpath(link_parent, "link")
            symlink(real_leaf, link_leaf)
            link_sh = DistSSHRun._remote_root_create_script(link_leaf; report = true)
            link_bad = run(pipeline(`sh -c $link_sh`; stdout = devnull, stderr = devnull); wait = false)
            wait(link_bad)
            @test link_bad.exitcode == 2
            trav = DistSSHRun._remote_root_ensure_under_home_script(
                home * "/a/../b", home,
            )
            trav_bad = run(pipeline(`sh -c $trav`; stdout = devnull, stderr = devnull); wait = false)
            wait(trav_bad)
            @test trav_bad.exitcode != 0
        end
        @test_throws ArgumentError DistSSHRun._remote_root_ensure_under_home_script("/", home)
        @test_throws ArgumentError DistSSHRun._remote_root_ensure_under_home_script(home, home)
        @test_throws ArgumentError DistSSHRun._remote_root_ensure_under_home_script(
            joinpath("/other", "x"), home,
        )
        # Concurrent ensure of the same absolute leaf.
        race_parent = joinpath(home, "race")
        mkpath(race_parent)
        race_leaf = joinpath(race_parent, "app")
        race_sh = DistSSHRun._remote_root_create_script(race_leaf; report = true)
        results = Vector{Int}(undef, 8)
        @sync for i in 1:8
            @async begin
                p = run(pipeline(`sh -c $race_sh`; stdout = devnull, stderr = devnull); wait = false)
                wait(p)
                results[i] = p.exitcode
            end
        end
        @test all(iszero, results)
        @test isdir(race_leaf)
        @test (filemode(race_leaf) & 0o022) == 0
    finally
        rm(home; force = true, recursive = true)
    end
end

@testset "tilde ensure remaps a logical home onto a physical home" begin
    logical = "/Users/dev"
    physical = "/var/home/dev"
    @test DistSSHRun._rehome_logical_under_physical_home(
        "/Users/dev/Parent/Repo", logical, physical,
    ) == "/var/home/dev/Parent/Repo"
    @test DistSSHRun._rehome_logical_under_physical_home(
        "/var/home/dev/Parent/Repo", logical, physical,
    ) == "/var/home/dev/Parent/Repo"
    @test DistSSHRun._rehome_logical_under_physical_home(
        "/Users/dev/Parent/Repo", logical, logical,
    ) == "/Users/dev/Parent/Repo"
    @test_throws ArgumentError DistSSHRun._rehome_logical_under_physical_home(
        "/Users/dev", logical, physical,
    )
    @test_throws ArgumentError DistSSHRun._rehome_logical_under_physical_home(
        "/tmp/other", logical, physical,
    )
    if !Sys.iswindows()
        _with_tempdir() do base
            physical_home = joinpath(base, "physical")
            logical_home = joinpath(base, "logical")
            mkpath(physical_home)
            symlink(physical_home, logical_home)
            logical_root = joinpath(logical_home, "Parent", "Repo")
            physical_root = DistSSHRun._rehome_logical_under_physical_home(
                logical_root, logical_home, physical_home,
            )
            @test physical_root == joinpath(physical_home, "Parent", "Repo")
            under = DistSSHRun._remote_root_ensure_under_home_script(
                physical_root, physical_home,
            )
            @test occursin("CREATED", read(`sh -c $under`, String))
            @test isdir(physical_root)
            @test (filemode(physical_root) & 0o022) == 0
            # Without remapping, a logical expansion fails the under-home check.
            @test_throws ArgumentError DistSSHRun._remote_root_ensure_under_home_script(
                logical_root, physical_home,
            )
        end
        _with_tempdir() do state_dir
            withenv(
                merge(
                    _fake_setup_remote_env(state_dir),
                    Dict(
                        "DISTSSHKIT_TEST_REMOTE_HOME" => "/var/home/dev",
                        "DISTSSHKIT_TEST_REMOTE_HOME_LOGICAL" => "/Users/dev",
                        "DISTSSHKIT_TEST_REMOTE_EXPAND" => "/Users/dev/Parent/Repo",
                    ),
                )...,
            ) do
                ensured = DistSSHRun._ensure_ship_remote_root!(
                    "host1", "~/Parent/Repo",
                )
                @test ensured.abs_root == "/var/home/dev/Parent/Repo"
                @test ensured.created
                @test isdir(joinpath(state_dir, "host1", "tree"))
            end
        end
    end
end

@testset "setup --remote-root creates only that directory" begin
    @test_throws ArgumentError DistSSHRun.explicit_remote_root_path("~/jobs/app")
    @test_throws ArgumentError DistSSHRun.explicit_remote_root_path("jobs/app")
    @test_throws ArgumentError DistSSHRun.explicit_remote_root_path("/")
    @test_throws ArgumentError DistSSHRun.explicit_remote_root_path("/tmp/app\n")
    @test_throws ArgumentError DistSSHRun.explicit_remote_root_path("/tmp/app\n ")
    @test DistSSHRun.explicit_remote_root_path("/tmp/jobs/app/") == "/tmp/jobs/app"
    sh = DistSSHRun._remote_root_create_script("/tmp/jobs/app")
    @test occursin("mkdir -m 700 ", sh)
    @test occursin("chmod go-w ", sh)
    @test !occursin("mkdir -p", sh)
    @test occursin("remote_root parent does not exist", sh)
    @test occursin("remote_root is a symlink", sh)
    @test occursin("group or world writable", sh)
    @test !occursin("runs", sh)
    @test !occursin(".distssh", sh)
    session = DistSSHRun.KitSession(; workers = ["child:host.test"], yes = true)
    err = try
        _capture_stdio() do _, _
            DistSSHRun.setup!(session, :remote_root)
        end
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("absolute path", sprint(showerror, err))
    parent = mktempdir()
    root = joinpath(parent, "app")
    try
        script = "umask 022\n" * DistSSHRun._remote_root_create_script(root)
        run(`sh -c $script`)
        @test isdir(root)
        @test (filemode(root) & 0o022) == 0
        loose = joinpath(parent, "loose")
        loose_script = "umask 002\n" * DistSSHRun._remote_root_create_script(loose)
        run(`sh -c $loose_script`)
        @test isdir(loose)
        @test (filemode(loose) & 0o022) == 0
        @test !isdir(joinpath(root, "runs"))
        chmod(root, 0o775)
        bad = run(pipeline(`sh -c $script`; stdout = devnull, stderr = devnull); wait = false)
        wait(bad)
        @test bad.exitcode == 2
        chmod(root, 0o755)
        run(`sh -c $script`)
        @test isdir(root)
        missing = joinpath(parent, "nope", "app")
        miss = DistSSHRun._remote_root_create_script(missing)
        miss_proc = run(pipeline(`sh -c $miss`; stdout = devnull, stderr = devnull); wait = false)
        wait(miss_proc)
        @test miss_proc.exitcode == 2
        @test !isdir(joinpath(parent, "nope"))
        file = joinpath(parent, "file")
        write(file, "x")
        file_script = DistSSHRun._remote_root_create_script(file)
        file_proc = run(pipeline(`sh -c $file_script`; stdout = devnull, stderr = devnull); wait = false)
        wait(file_proc)
        @test file_proc.exitcode == 2
        link = joinpath(parent, "link")
        symlink(root, link)
        link_script = DistSSHRun._remote_root_create_script(link)
        link_proc = run(pipeline(`sh -c $link_script`; stdout = devnull, stderr = devnull); wait = false)
        wait(link_proc)
        @test link_proc.exitcode == 2
        @test islink(link)
    finally
        rm(parent; force = true, recursive = true)
    end
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

@testset "ship-tree size warnings" begin
    _with_tempdir() do tmp
        write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
        mkpath(joinpath(tmp, "data"))
        write(joinpath(tmp, "data", "big.bin"), "abcdef")
        write(joinpath(tmp, "a.jl"), "1\n")
        text = mktemp() do _, io
            packed = withenv(
                "DISTSSHKIT_SHIP_WARN_FILE_BYTES" => "1",
                "DISTSSHKIT_SHIP_WARN_TOTAL_BYTES" => "1",
            ) do
                redirect_stdout(io) do
                    redirect_stderr(() -> DistSSHRun.pack_ship_tar(tmp), io)
                end
            end
            try
                @test isfile(packed.tar_path)
            finally
                rm(packed.tmpd; force = true, recursive = true)
            end
            flush(io)
            seekstart(io)
            return read(io, String)
        end
        @test occursin("data/big.bin", text)
        @test occursin("send list is", text)
        @test occursin("Largest directories", text)
        @test occursin("data (", text)
        err = try
            withenv("DISTSSHKIT_SHIP_WARN_TOTAL_BYTES" => "nope") do
                DistSSHRun.pack_ship_tar(tmp)
            end
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("DISTSSHKIT_SHIP_WARN_TOTAL_BYTES", err.msg)
        warned = mktemp() do _, io
            thrown = redirect_stdout(io) do
                try
                    withenv("DISTSSHKIT_SHIP_WARN_TOTAL_BYTES" => "0") do
                        DistSSHRun.pack_ship_tar(tmp; ship_max_bytes = 1)
                    end
                    nothing
                catch e
                    e
                end
            end
            flush(io)
            seekstart(io)
            return thrown, read(io, String)
        end
        @test warned[1] isa ArgumentError
        @test occursin("cap 1", warned[1].msg)
        @test occursin("send list is", warned[2])
    end
end

@testset "gitignored project preferences stay out of the ship" begin
    _with_tempdir() do tmp
        write(joinpath(tmp, ".gitignore"), "LocalPreferences.toml\nJuliaLocalPreferences.toml\n")
        write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
        write(joinpath(tmp, "LocalPreferences.toml"), "[ShipT]\nx = 1\n")
        write(joinpath(tmp, "JuliaLocalPreferences.toml"), "[ShipT]\ny = 2\n")
        packed = DistSSHRun.pack_ship_tar(tmp)
        try
            dest = mktempdir()
            DistSSHRun.Tar.extract(packed.tar_path, dest)
            @test !isfile(joinpath(dest, "LocalPreferences.toml"))
            @test !islink(joinpath(dest, "LocalPreferences.toml"))
            @test !isfile(joinpath(dest, "JuliaLocalPreferences.toml"))
        finally
            rm(packed.tmpd; force = true, recursive = true)
        end
    end
end

@testset "a project preference symlink ships as a symlink" begin
    _with_tempdir() do tmp
        write(joinpath(tmp, "Project.toml"), "name = \"ShipT\"\n")
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
        write(joinpath(tmp, "prefs.toml"), "[ShipT]\nx = 1\n")
        symlink("prefs.toml", joinpath(tmp, "LocalPreferences.toml"))
        packed = DistSSHRun.pack_ship_tar(tmp)
        try
            dest = mktempdir()
            DistSSHRun.Tar.extract(packed.tar_path, dest)
            @test islink(joinpath(dest, "LocalPreferences.toml"))
        finally
            rm(packed.tmpd; force = true, recursive = true)
        end
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
        @test occursin("files=", probe)
        @test occursin("input filename contains a newline", probe)
        @test occursin("JULIA_DEPOT_PATH=", probe)
        @test !occursin("sha256sum", probe)
        @test !occursin("shasum", probe)
        hashed = DistSSHRun._remote_input_probe_sh("/remote/data", true)
        @test occursin("sha256_file", hashed)
        @test occursin("PROG ", hashed)
        @test !occursin("sha256sum", hashed)
        @test !occursin("shasum", hashed)
        run_dir = mktempdir()
        DistSSHRun._store_input_rows!(
            run_dir,
            [
                Dict{String, Any}(
                    "name" => "big",
                    "path" => "data",
                    "host" => "h",
                    "verification" => "stat",
                ),
            ],
        )
        @test isfile(joinpath(run_dir, "inputs", "records.toml"))
        @test !isfile(joinpath(tmp, "inputs.toml"))
        @test !isfile(joinpath(tmp, "inputs", "records.toml"))
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
        write(joinpath(root, "sub", ".hidden"), "h\n")
        write(joinpath(other, "sub", ".hidden"), "h\n")
        symlink(root, link)
        rec_dir = mktempdir()
        function probe_row(tree, do_hash)
            script = DistSSHRun._remote_input_probe_sh(tree, do_hash)
            out = read(pipeline(`sh -c $script`; stderr = devnull), String)
            return DistSSHRun._input_row_from_probe("n", "p", "h", do_hash, out, rec_dir)
        end
        hashed = probe_row(root, true)
        @test hashed["algorithm"] == "sha256-manifest-v1"
        @test hashed["verification"] == "sha256"
        @test hashed["files"] == 2
        @test haskey(hashed, "content_hash")
        @test !haskey(hashed, "stat_digest")
        @test occursin(r"^[0-9a-f]{64}$", hashed["content_hash"])
        manifest = String(read(joinpath(rec_dir, hashed["manifest"]), String))
        @test occursin(" *sub/a.txt", manifest)
        @test occursin(" *sub/.hidden", manifest)
        @test hashed["content_hash"] == probe_row(other, true)["content_hash"]
        @test hashed["content_hash"] == probe_row(link, true)["content_hash"]
        manifest_path = joinpath(rec_dir, hashed["manifest"])
        DistSSHRun.check_input_manifest(manifest_path, root)
        write(joinpath(root, "sub", "a.txt"), "changed\n")
        @test_throws ArgumentError DistSSHRun.check_input_manifest(manifest_path, root)
        @test hashed["content_hash"] != probe_row(root, true)["content_hash"]
        write(joinpath(root, "sub", "a.txt"), "hi\n")
        symlink("a.txt", joinpath(root, "sub", "via"))
        with_link = probe_row(root, true)
        @test with_link["content_hash"] != hashed["content_hash"]
        @test occursin(" *sub/via", String(read(joinpath(rec_dir, with_link["manifest"]), String)))
        link_manifest = joinpath(rec_dir, with_link["manifest"])
        DistSSHRun.check_input_manifest(link_manifest, root)
        rm(joinpath(root, "sub", "via"))
        symlink("other", joinpath(root, "sub", "via"))
        @test_throws ArgumentError DistSSHRun.check_input_manifest(link_manifest, root)
        rm(joinpath(root, "sub", "via"))
        symlink("a.txt", joinpath(root, "sub", "via"))
        stat_row = probe_row(other, false)
        @test stat_row["verification"] == "stat"
        @test stat_row["algorithm"] == "stat"
        @test !haskey(stat_row, "content_hash")
        @test stat_row["files"] == 2
        @test occursin(r"^[0-9a-f]{64}$", stat_row["stat_digest"])
        @test occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", stat_row["hashed_at"])
        nfc_dir = mktempdir()
        hex = DistSSHRun._sha256_hex(Vector{UInt8}("hi"))
        nfd = "file\t2\t$(hex)\tcaf\u0065\u0301.txt"
        nfc_row = DistSSHRun._input_row_from_probe("n", "p", "nfc", true, nfd, nfc_dir)
        nfc_body = String(read(joinpath(nfc_dir, nfc_row["manifest"])))
        @test occursin(" *caf\u00e9.txt", nfc_body)
        @test !occursin('\u0301', nfc_body)
        @test DistSSHRun._format_bytes(1536) == "1.5 KB"
        @test DistSSHRun._input_summary_line("sim_input", 1536, 41, false) ==
            "hashed sim_input: 1.5 KB in 41 s"
        toml_dir = mktempdir()
        DistSSHRun._store_input_rows!(toml_dir, [stat_row])
        DistSSHRun.write_kit_run_toml!(toml_dir; kind = :go)
        recorded = something(DistSSHRun.read_kit_run_toml(toml_dir))
        @test recorded["inputs"] isa Vector
        @test recorded["inputs"][1]["verification"] == "stat"
        @test !haskey(recorded["inputs"][1], "content_hash")
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
        rm(joinpath(root, "sub", "a\nb.txt"); force = true)
        symlink("a.txt\n", joinpath(root, "sub", "badlink"))
        link_nl = DistSSHRun._remote_input_probe_sh(root, true)
        link_out = IOBuffer()
        link_proc = run(pipeline(`sh -c $link_nl`; stdout = link_out, stderr = devnull); wait = false)
        wait(link_proc)
        @test link_proc.exitcode == 2
        @test occursin("link target contains a newline", String(take!(link_out)))
        @test_throws ArgumentError DistSSHRun._nfc_input_rel("a\\b")
        @test_throws ArgumentError DistSSHRun._canonical_ship_input_path("data\\file")
        left = DistSSHRun._input_manifest_rel("a--b", "c")
        right = DistSSHRun._input_manifest_rel("a", "b--c")
        @test left != right
        @test occursin(r"^inputs/[0-9a-f]{64}\.manifest$", left)
        @test occursin(r"^inputs/[0-9a-f]{64}\.manifest$", right)
        root_link = joinpath(dirname(root), "declared-root-link-" * basename(root))
        symlink("a.txt\n", root_link)
        try
            root_nl = DistSSHRun._remote_input_probe_sh(root_link, true)
            root_out = IOBuffer()
            root_proc = run(pipeline(`sh -c $root_nl`; stdout = root_out, stderr = devnull); wait = false)
            wait(root_proc)
            @test root_proc.exitcode == 2
            @test occursin("link target contains a newline", String(take!(root_out)))
        finally
            rm(root_link; force = true)
        end
    finally
        rm(link; force = true)
        rm(root; force = true, recursive = true)
        rm(other; force = true, recursive = true)
    end
end

@testset "a file input is one sha256sum line" begin
    parent = mktempdir()
    file = joinpath(parent, "one.bin")
    write(file, "hi\n")
    rec = mktempdir()
    try
        hashed_out = read(
            pipeline(`sh -c $(DistSSHRun._remote_input_probe_sh(file, true))`; stderr = devnull),
            String,
        )
        hashed = DistSSHRun._input_row_from_probe("n", "dir/one.bin", "h", true, hashed_out, rec)
        body = String(read(joinpath(rec, hashed["manifest"])))
        @test occursin(" *one.bin", body)
        @test !occursin(" *.", body)
        DistSSHRun.check_input_manifest(joinpath(rec, hashed["manifest"]), parent)
        stat_out = read(
            pipeline(`sh -c $(DistSSHRun._remote_input_probe_sh(file, false))`; stderr = devnull),
            String,
        )
        stat_row = DistSSHRun._input_row_from_probe("n", "dir/one.bin", "h", false, stat_out, rec)
        @test stat_row["verification"] == "stat"
        @test stat_row["files"] == 1
        @test stat_row["bytes"] == 3
        @test occursin(r"^[0-9a-f]{64}$", stat_row["stat_digest"])
    finally
        rm(parent; force = true, recursive = true)
        rm(rec; force = true, recursive = true)
    end
end

@testset "a root symlink to a file is a link record" begin
    parent = mktempdir()
    target = joinpath(parent, "payload.bin")
    link = joinpath(parent, "alias.bin")
    write(target, "hi\n")
    symlink("payload.bin", link)
    rec = mktempdir()
    try
        out = read(
            pipeline(`sh -c $(DistSSHRun._remote_input_probe_sh(link, true))`; stderr = devnull),
            String,
        )
        @test startswith(out, "link\t")
        row = DistSSHRun._input_row_from_probe("n", "dir/alias.bin", "h", true, out, rec)
        body = String(read(joinpath(rec, row["manifest"])))
        @test occursin(" *alias.bin", body)
        DistSSHRun.check_input_manifest(joinpath(rec, row["manifest"]), parent)
    finally
        rm(parent; force = true, recursive = true)
        rm(rec; force = true, recursive = true)
    end
end

@testset "julia input probe matches the frozen sh probe" begin
    root = mktempdir()
    fixture = normpath(joinpath(@__DIR__, "..", "..", "fixtures", "remote_input_probe.sh"))
    function capture(cmd)
        out = IOBuffer()
        err = IOBuffer()
        proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err); wait = true)
        return (Int(something(proc.exitcode, 1)), String(take!(out)), String(take!(err)))
    end
    try
        mkpath(joinpath(root, "sub"))
        write(joinpath(root, "sub", "a.txt"), "hi\n")
        write(joinpath(root, "z.txt"), "yo")
        symlink("a.txt", joinpath(root, "sub", "via"))
        symlink("missing-target", joinpath(root, "broken"))
        file = joinpath(root, "z.txt")
        for (path, flag) in ((root, "1"), (root, "0"), (file, "1"), (file, "0"), (joinpath(root, "broken"), "1"))
            old = capture(`sh $fixture $path $flag`)
            new = capture(`sh -c $(DistSSHRun._remote_input_probe_sh(path, flag == "1"))`)
            @test new[1] == old[1]
            @test new[2] == old[2]
            @test new[3] == old[3]
        end
        hex = DistSSHRun._sha256_file(file)
        summed = if Sys.which("sha256sum") !== nothing
            read(`sha256sum $file`, String)
        else
            read(`shasum -a 256 $file`, String)
        end
        @test startswith(lowercase(summed), hex)
        wide = joinpath(root, "wide.bin")
        open(wide, "w") do io
            write(io, zeros(UInt8, 65536 * 2 + 3))
        end
        @test DistSSHRun._sha256_file(wide) == DistSSHRun._sha256_hex(read(wide))
    finally
        rm(root; force = true, recursive = true)
    end
end

@testset "check_input_manifest matches NFC to an NFD name" begin
    root = mktempdir()
    try
        nfd = "cafe\u0301.txt"
        nfc = DistSSHRun.Unicode.normalize(nfd, :NFC)
        write(joinpath(root, nfd), "hi\n")
        names = readdir(root)
        stored = only(filter(!=("."), names))
        DistSSHRun.Unicode.normalize(stored, :NFC) == nfc || return
        stored == nfc && return
        hex = DistSSHRun._sha256_hex(Vector{UInt8}("hi\n"))
        man = joinpath(root, "m.manifest")
        write(man, "$hex *$nfc\n")
        @test DistSSHRun.check_input_manifest(man, root) === nothing
    finally
        rm(root; force = true, recursive = true)
    end
end

@testset "await_inputs defers until await_declared_input_hashes!" begin
    DistSSHRun.await_declared_input_hashes!()
    @test isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)
    started = Ref(false)
    finished = Ref(false)
    task = @async begin
        started[] = true
        sleep(0.05)
        finished[] = true
        return nothing
    end
    lock(DistSSHRun._PENDING_INPUT_HASH_LOCK) do
        push!(DistSSHRun._PENDING_INPUT_HASH_TASKS, task)
    end
    @test !finished[]
    DistSSHRun.await_declared_input_hashes!()
    @test started[]
    @test finished[]
    @test isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)
    second_done = Ref(false)
    bad = @async error("hash failed")
    good = @async begin
        sleep(0.05)
        second_done[] = true
        return nothing
    end
    lock(DistSSHRun._PENDING_INPUT_HASH_LOCK) do
        push!(DistSSHRun._PENDING_INPUT_HASH_TASKS, bad, good)
    end
    err = try
        DistSSHRun.await_declared_input_hashes!()
        nothing
    catch e
        e
    end
    @test err isa TaskFailedException
    @test second_done[]
    @test isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)
    gate = Channel{Bool}(1)
    slow_done = Ref(false)
    slow = @async begin
        take!(gate)
        slow_done[] = true
        return nothing
    end
    lock(DistSSHRun._PENDING_INPUT_HASH_LOCK) do
        push!(DistSSHRun._PENDING_INPUT_HASH_TASKS, slow)
    end
    waiter = @async DistSSHRun.await_declared_input_hashes!()
    for _ in 1:200
        (istaskstarted(waiter) && !istaskdone(waiter)) && break
        sleep(0.01)
    end
    sleep(0.05)
    schedule(waiter, InterruptException(); error = true)
    sleep(0.05)
    @test !slow_done[]
    @test !istaskdone(slow)
    put!(gate, true)
    interrupted = try
        fetch(waiter)
        nothing
    catch e
        e isa TaskFailedException ? e.task.exception : e
    end
    @test interrupted isa InterruptException
    @test slow_done[]
    @test isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)
    gate2 = Channel{Bool}(1)
    finished2 = Ref(false)
    bad_first = @async error("hash failed first")
    slow2 = @async begin
        take!(gate2)
        finished2[] = true
        return nothing
    end
    lock(DistSSHRun._PENDING_INPUT_HASH_LOCK) do
        push!(DistSSHRun._PENDING_INPUT_HASH_TASKS, bad_first, slow2)
    end
    waiter2 = @async DistSSHRun.await_declared_input_hashes!()
    for _ in 1:200
        (istaskstarted(waiter2) && !istaskdone(waiter2)) && break
        sleep(0.01)
    end
    sleep(0.05)
    schedule(waiter2, InterruptException(); error = true)
    sleep(0.05)
    put!(gate2, true)
    prefer_interrupt = try
        fetch(waiter2)
        nothing
    catch e
        e isa TaskFailedException ? e.task.exception : e
    end
    @test prefer_interrupt isa InterruptException
    @test finished2[]
    @test isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)
    @test hasmethod(
        DistSSHRun.ship_project_to_hosts!,
        Tuple{Vector{String}, String, String},
        (:await_inputs,),
    )
end

@testset "init joins overlapped hash after an interrupted fetch" begin
    # Both `init_drive_workers!` exits call `_join_overlapped_input_hash!`.
    # The overlapped task has already drained the pending list, so this join
    # is what keeps hashing from outliving the interrupt.
    DistSSHRun.await_declared_input_hashes!()
    try
        gate = Channel{Bool}(1)
        finished = Ref(false)
        slow = @async begin
            take!(gate)
            finished[] = true
            return nothing
        end
        lock(DistSSHRun._PENDING_INPUT_HASH_LOCK) do
            push!(DistSSHRun._PENDING_INPUT_HASH_TASKS, slow)
        end
        hash_task = @async DistSSHRun.await_declared_input_hashes!()
        waiter = @async DistSSHRun._join_overlapped_input_hash!(hash_task)
        for _ in 1:200
            (istaskstarted(waiter) && !istaskdone(waiter) && isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)) &&
                break
            sleep(0.01)
        end
        sleep(0.05)
        schedule(waiter, InterruptException(); error = true)
        sleep(0.05)
        @test !finished[]
        @test !istaskdone(slow)
        @test !istaskdone(hash_task)
        @test !istaskdone(waiter)
        @test isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)
        put!(gate, true)
        interrupted = try
            fetch(waiter)
            nothing
        catch e
            e isa TaskFailedException ? e.task.exception : e
        end
        @test interrupted isa InterruptException
        @test finished[]
        @test istaskdone(hash_task)
        @test isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)

        gate_fail = Channel{Bool}(1)
        failed = Ref(false)
        bad = @async begin
            take!(gate_fail)
            failed[] = true
            error("hash failed during init")
        end
        lock(DistSSHRun._PENDING_INPUT_HASH_LOCK) do
            push!(DistSSHRun._PENDING_INPUT_HASH_TASKS, bad)
        end
        hash_fail = @async DistSSHRun.await_declared_input_hashes!()
        waiter_fail = @async DistSSHRun._join_overlapped_input_hash!(hash_fail)
        for _ in 1:200
            (
                istaskstarted(waiter_fail) && !istaskdone(waiter_fail) &&
                    isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)
            ) && break
            sleep(0.01)
        end
        sleep(0.05)
        schedule(waiter_fail, InterruptException(); error = true)
        sleep(0.05)
        @test !failed[]
        @test !istaskdone(waiter_fail)
        put!(gate_fail, true)
        prefer_interrupt = try
            fetch(waiter_fail)
            nothing
        catch e
            e isa TaskFailedException ? e.task.exception : e
        end
        @test prefer_interrupt isa InterruptException
        @test failed[]
        @test istaskfailed(hash_fail)
        @test isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)

        lock(DistSSHRun._PENDING_INPUT_HASH_LOCK) do
            push!(DistSSHRun._PENDING_INPUT_HASH_TASKS, @async error("hash failed alone"))
        end
        alone_task = @async DistSSHRun.await_declared_input_hashes!()
        alone = try
            DistSSHRun._join_overlapped_input_hash!(alone_task)
            nothing
        catch e
            e
        end
        @test alone isa TaskFailedException
        @test isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)

        lock(DistSSHRun._PENDING_INPUT_HASH_LOCK) do
            push!(DistSSHRun._PENDING_INPUT_HASH_TASKS, @async error("hash failed after init"))
        end
        after_init = @async DistSSHRun.await_declared_input_hashes!()
        @test_logs (:warn, r"Declared-input hashing failed") DistSSHRun._join_overlapped_input_hash_keep_prior!(
            after_init,
        )
        @test istaskfailed(after_init)
        @test isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)

        gate_keep = Channel{Bool}(1)
        kept_failed = Ref(false)
        bad_keep = @async begin
            take!(gate_keep)
            kept_failed[] = true
            error("hash failed during init catch")
        end
        lock(DistSSHRun._PENDING_INPUT_HASH_LOCK) do
            push!(DistSSHRun._PENDING_INPUT_HASH_TASKS, bad_keep)
        end
        hash_keep = @async DistSSHRun.await_declared_input_hashes!()
        waiter_keep = @async DistSSHRun._join_overlapped_input_hash_keep_prior!(hash_keep)
        for _ in 1:200
            (
                istaskstarted(waiter_keep) && !istaskdone(waiter_keep) &&
                    isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)
            ) && break
            sleep(0.01)
        end
        sleep(0.05)
        schedule(waiter_keep, InterruptException(); error = true)
        sleep(0.05)
        @test !kept_failed[]
        @test !istaskdone(waiter_keep)
        put!(gate_keep, true)
        keep_interrupt = try
            fetch(waiter_keep)
            nothing
        catch e
            e isa TaskFailedException ? e.task.exception : e
        end
        @test keep_interrupt isa InterruptException
        @test kept_failed[]
        @test istaskfailed(hash_keep)
        @test isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)
    finally
        try
            DistSSHRun.await_declared_input_hashes!()
        catch
        end
    end
end

@testset "declared input rows land in run.toml" begin
    run_dir = mktempdir()
    try
        DistSSHRun.write_kit_run_toml!(run_dir; kind = :go)
        DistSSHRun._commit_declared_input_rows!(
            run_dir,
            [Dict{String, Any}("name" => "a", "host" => "h", "verification" => "stat")],
        )
        DistSSHRun._commit_declared_input_rows!(
            run_dir,
            [Dict{String, Any}("name" => "b", "host" => "h", "verification" => "stat")],
        )
        DistSSHRun._commit_declared_input_rows!(
            run_dir,
            [Dict{String, Any}("name" => "a", "host" => "h", "verification" => "sha256", "content_hash" => "x")],
        )
        stored = DistSSHRun._read_declared_input_rows(run_dir)
        @test length(stored) == 2
        recorded = something(DistSSHRun.read_kit_run_toml(run_dir))
        @test length(recorded["inputs"]) == 2
        @test recorded["inputs"][1]["name"] == "b"
        @test recorded["inputs"][2]["name"] == "a"
        @test recorded["inputs"][2]["verification"] == "sha256"
    finally
        rm(run_dir; force = true, recursive = true)
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

@testset "last-ship src helper is scoped to hosts and remote_root" begin
    DistSSHRun._clear_last_ship!()
    DistSSHRun._LAST_SHIP[] = Dict{String, Any}(
        "src" => "/home/dev/app/runs/20260101T000000Z-abcdef/src",
        "run_id" => "20260101T000000Z-abcdef",
        "hosts" => String["child-1"],
        "remote_root" => "/home/dev/app",
    )
    DistSSHRun._SHIP_LAYOUT_ACTIVE[] = true
    try
        @test DistSSHRun._last_ship_src_for(["child-1"], "/home/dev/app") ==
            "/home/dev/app/runs/20260101T000000Z-abcdef/src"
        @test DistSSHRun._last_ship_src_for(["child-2"], "/home/dev/app") === nothing
        @test DistSSHRun._last_ship_src_for(["child-1"], "/other") === nothing
        @test DistSSHRun._last_ship_src_for(["child-1"], "/home/dev/app/pkg") === nothing
        wr = "/home/dev/app/runs/20260101T000000Z-abcdef/src"
        @test DistSSHRun._rehome_under_work_root(
            "/home/dev/app/pkg", "/home/dev/app", wr,
        ) == "/home/dev/app/runs/20260101T000000Z-abcdef/src/pkg"
    finally
        DistSSHRun._clear_last_ship!()
    end
end

@testset "project work root rehomes workspace member onto selected src" begin
    # Pure rehome mapping (selection itself is covered in snapshot_select.jl).
    wr = "/home/dev/app/runs/20260101T000000Z-abcdef/src"
    @test DistSSHRun._rehome_under_work_root(
        "/home/dev/app/pkg", "/home/dev/app", wr,
    ) == "/home/dev/app/runs/20260101T000000Z-abcdef/src/pkg"
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

@testset "work layout ignores poisoned DISTRIBUTED_REMOTE_PROJECT_ROOT" begin
    _with_tempdir() do proj
        write(joinpath(proj, "Project.toml"), "name = \"LayoutPoison\"\n")
        write(
            joinpath(proj, "Manifest.toml"),
            "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
        )
        mkpath(joinpath(proj, "output"))
        deploy = "/home/dev/app"
        work = "/home/dev/app/runs/20260101T000000Z-abcdef/src"
        DistSSHRun._set_active_selection!(
            DistSSHRun.SnapshotSelection(
                :snapshot,
                "20260101T000000Z-abcdef",
                deploy,
                work,
                "deadbeef",
                ["child-1"],
            ),
        )
        try
            withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => work) do
                got = DistSSHRun._remote_work_layout_path(
                    joinpath(proj, "output"), proj, ["child-1"],
                )
                @test got == "$work/output"
                @test !occursin("/runs/20260101T000000Z-abcdef/src/runs/", got)
            end
        finally
            DistSSHRun._clear_last_ship!()
        end
    end
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

@testset "ship remote status uses shell_status" begin
    double = joinpath(@__DIR__, "..", "..", "..", "lib", "DistSSHBase", "test", "fixtures", "fake_shell_ssh.jl")
    @test isfile(double)
    _with_tempdir() do dir
        logp = joinpath(dir, "ssh.log")
        ready = joinpath(dir, "ready")
        env = Dict{String, String}(
            "DISTSSHKIT_TEST" => "1",
            "DISTSSHKIT_TEST_SSH" => double,
            "SHELL_DOUBLE_LOG" => logp,
            "SHELL_DOUBLE_MODE" => "sleep",
            "SHELL_DOUBLE_READY" => ready,
            "DISTSSHKIT_TEST_POSIX_SHELL" => "1",
        )
        try
            withenv(env...) do
                task = @async DistSSHRun._remote_script_output((_ -> nothing), "ship-sig.test", "sleep")
                _kill_ready_child(ready; signal = Base.SIGTERM)
                code, _, _ = fetch(task)
                @test code == 143
            end

            rm(ready; force = true)
            tar = joinpath(dir, "pull.tar")
            write(tar, "")
            err = withenv(env...) do
                err_task = @async try
                    DistSSHRun._remote_extract_tar!("ship-tar.test", "/remote/src", tar, "julia")
                    nothing
                catch e
                    e
                end
                _kill_ready_child(ready; signal = Base.SIGTERM)
                return fetch(err_task)
            end
            @test err isa ArgumentError
            @test occursin("tar extract failed", err.msg)
        finally
            DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
        end
    end
end

@testset "snapshot is sent without packing again" begin
    function _project!(dir::String)
        write(joinpath(dir, "Project.toml"), "name = \"Snap\"\n")
        write(joinpath(dir, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
        write(joinpath(dir, "a.jl"), "1\n")
        return dir
    end
    function _restore_ship!(previous, active)
        DistSSHRun._LAST_SHIP[] = previous
        DistSSHRun._SHIP_LAYOUT_ACTIVE[] = active
        return nothing
    end
    function _with_saved_project_env(f::Function)
        old_proj = get(ENV, "DISTRIBUTED_PROJECT_ROOT", nothing)
        old_remote = get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", nothing)
        try
            return f()
        finally
            if old_proj === nothing
                delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
            else
                ENV["DISTRIBUTED_PROJECT_ROOT"] = old_proj
            end
            if old_remote === nothing
                delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
            else
                ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = old_remote
            end
        end
    end

    _with_tempdir() do proj
        _project!(proj)
        snap = DistSSHRun.snapshot(proj)
        try
            tar = DistSSHRun.snapshot_tar(snap)
            @test tar == joinpath(DistSSHRun.snapshot_directory(snap), "ship.tar")
            @test isfile(tar)
            @test DistSSHRun.content_tree_hash(snap) ==
                DistSSHRun._ship_tar_tree_hash(tar)
            @test DistSSHRun.content_tree_hash(snap) != ""
            write(joinpath(proj, "a.jl"), "2\n")
            other = DistSSHRun.snapshot(proj)
            try
                @test DistSSHRun.content_tree_hash(other) != DistSSHRun.content_tree_hash(snap)
                cp(DistSSHRun.snapshot_tar(other), tar; force = true)
                err = try
                    DistSSHRun.ship(snap, ["host1"], "/home/distsshkit/app"; confirm = false)
                    nothing
                catch e
                    e
                end
                @test err isa ArgumentError
                @test occursin("does not match snapshot", sprint(showerror, err))
                @test isfile(tar)
            finally
                rm(DistSSHRun.snapshot_directory(other); force = true, recursive = true)
            end
        finally
            rm(DistSSHRun.snapshot_directory(snap); force = true, recursive = true)
        end
    end

    _with_tempdir() do proj
        _project!(proj)
        depot = mktempdir()
        mkpath(joinpath(depot, "artifacts"))
        write(joinpath(depot, "artifacts", "Overrides.toml"), "x = 1\n")
        old = copy(Base.DEPOT_PATH)
        empty!(Base.DEPOT_PATH)
        push!(Base.DEPOT_PATH, depot)
        snap = nothing
        try
            snap = DistSSHRun.snapshot(proj)
            @test isfile(DistSSHRun.snapshot_tar(snap))
            err = try
                DistSSHRun.ship(snap, ["host1"], "/home/distsshkit/app")
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("depot preferences", sprint(showerror, err))
            @test isfile(DistSSHRun.snapshot_tar(snap))
        finally
            empty!(Base.DEPOT_PATH)
            append!(Base.DEPOT_PATH, old)
            snap === nothing || rm(DistSSHRun.snapshot_directory(snap); force = true, recursive = true)
            rm(depot; force = true, recursive = true)
        end
    end

    _with_tempdir() do proj
        _project!(proj)
        previous = DistSSHRun._LAST_SHIP[]
        active = DistSSHRun._SHIP_LAYOUT_ACTIVE[]
        prev_ni = DistSSHRun.kit_noninteractive()
        DistSSHRun.set_kit_noninteractive!(false)
        try
            _with_saved_project_env() do
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:host1"],
                    remote = "/home/distsshkit/app",
                    yes = false,
                    quiet = true,
                )
                out, res = _capture_stdio() do stdin_io, _
                    println(stdin_io, "")
                    flush(stdin_io)
                    seekstart(stdin_io)
                    return DistSSHRun.sync!(session; mode = :ship_tree)
                end
                @test res.cancelled
                @test !res.ok
                @test occursin("Cancelled.", out)
                @test DistSSHRun.result_content_tree_hash(res) !== nothing
                @test occursin(DistSSHRun._RUN_ID_PATTERN, something(DistSSHRun.result_remote_run_id(res)))
            end
        finally
            DistSSHRun.set_kit_noninteractive!(prev_ni)
            _restore_ship!(previous, active)
        end
    end

    _with_tempdir() do state_dir
        prev_ni = DistSSHRun.kit_noninteractive()
        prev_verb = DistSSHRun.kit_verbosity()
        try
            _with_saved_project_env() do
                withenv(
                    merge(
                        _fake_setup_remote_env(state_dir),
                        Dict("DISTSSHKIT_TEST_JULIA_WHICH" => "/usr/bin/julia"),
                    )...,
                ) do
                    _apply_quiet_setup_session!()
                    _with_tempdir() do proj
                        _project!(proj)
                        previous = DistSSHRun._LAST_SHIP[]
                        active = DistSSHRun._SHIP_LAYOUT_ACTIVE[]
                        snap = DistSSHRun.snapshot(proj)
                        try
                            sentinel = Dict{String, Any}("content_tree_hash" => "keep-me")
                            DistSSHRun._LAST_SHIP[] = sentinel
                            DistSSHRun._SHIP_LAYOUT_ACTIVE[] = false
                            quiet = DistSSHRun.ship(
                                snap, ["host1"], "/home/distsshkit/app";
                                confirm = false, record = false,
                            )
                            @test quiet isa DistSSHRun.ShipTreeResult
                            @test !quiet.cancelled
                            @test all(hr -> hr.ok, quiet.host_results)
                            @test DistSSHRun._LAST_SHIP[] === sentinel
                            @test DistSSHRun._SHIP_LAYOUT_ACTIVE[] == false
                            @test isfile(DistSSHRun.snapshot_tar(snap))
                            @test DistSSHRun.result_content_tree_hash(quiet) ==
                                DistSSHRun.content_tree_hash(snap)
                            @test occursin(
                                DistSSHRun._RUN_ID_PATTERN,
                                something(DistSSHRun.result_remote_run_id(quiet)),
                            )
                            recorded = DistSSHRun.ship(
                                snap, ["host1"], "/home/distsshkit/app";
                                confirm = false, record = true,
                            )
                            kept = something(DistSSHRun._LAST_SHIP[])
                            @test kept isa Dict{String, Any}
                            @test kept["content_tree_hash"] ==
                                DistSSHRun.content_tree_hash(snap)
                            @test kept["run_id"] ==
                                DistSSHRun.result_remote_run_id(recorded)
                            @test DistSSHRun._SHIP_LAYOUT_ACTIVE[]
                            @test isfile(DistSSHRun.snapshot_tar(snap))

                            before = Set(readdir(tempdir()))
                            wrapped = DistSSHRun.ship_project_to_hosts!(
                                ["host1"], proj, "/home/distsshkit/app"; confirm = false,
                            )
                            @test all(hr -> hr.ok, wrapped.host_results)
                            for name in setdiff(Set(readdir(tempdir())), before)
                                @test !isfile(joinpath(tempdir(), name, "ship.tar"))
                            end
                            session = DistSSHRun.KitSession(
                                project = proj,
                                workers = ["child:host1"],
                                remote = "/home/distsshkit/app",
                                yes = true,
                                quiet = true,
                            )
                            synced = DistSSHRun.setup!(session, :ship_tree)
                            @test synced isa DistSSHRun.SyncResult
                            @test synced.ok && !synced.cancelled
                            @test DistSSHRun.result_content_tree_hash(synced) ==
                                DistSSHRun.content_tree_hash(snap)
                            @test DistSSHRun.result_remote_run_id(synced) !== nothing
                            @test any(hr -> occursin("ship-tree ok", hr.message), synced.hosts)
                            other = DistSSHRun.SyncResult(false, DistSSHRun.HostResult[]; ok = true)
                            @test DistSSHRun.result_content_tree_hash(other) === nothing
                            @test DistSSHRun.result_remote_run_id(other) === nothing
                        finally
                            rm(DistSSHRun.snapshot_directory(snap); force = true, recursive = true)
                            _restore_ship!(previous, active)
                        end
                    end
                end
            end
        finally
            DistSSHRun.set_kit_noninteractive!(prev_ni)
            DistSSHRun.set_kit_verbosity!(prev_verb)
        end
    end

    # Fresh absolute root: ensure creates it; extract failure leaves the directory.
    _with_tempdir() do state_dir
        prev_ni = DistSSHRun.kit_noninteractive()
        prev_verb = DistSSHRun.kit_verbosity()
        try
            _with_saved_project_env() do
                withenv(
                    merge(
                        _fake_setup_remote_env(state_dir),
                        Dict(
                            "DISTSSHKIT_TEST_JULIA_WHICH" => "/usr/bin/julia",
                            "DISTSSHKIT_TEST_REMOTE_HOME" => "/home/distsshkit",
                        ),
                    )...,
                ) do
                    _apply_quiet_setup_session!()
                    _with_tempdir() do proj
                        _project!(proj)
                        tree = joinpath(state_dir, "host1", "tree")
                        @test !isdir(tree)
                        previous = DistSSHRun._LAST_SHIP[]
                        active = DistSSHRun._SHIP_LAYOUT_ACTIVE[]
                        try
                            created = DistSSHRun.ship_project_to_hosts!(
                                ["host1"], proj, "/home/distsshkit/app"; confirm = false,
                            )
                            @test all(hr -> hr.ok, created.host_results)
                            @test any(
                                hr -> occursin("created remote_root", hr.message),
                                created.host_results,
                            )
                            @test isdir(tree)
                        finally
                            _restore_ship!(previous, active)
                        end
                    end
                end
                # Transfer failure after ensure must keep the root.
                withenv(
                    merge(
                        _fake_setup_remote_env(state_dir),
                        Dict(
                            "DISTSSHKIT_TEST_JULIA_WHICH" => "/usr/bin/julia",
                            "DISTSSHKIT_TEST_TAR_EXTRACT_FAIL" => "1",
                        ),
                    )...,
                ) do
                    _apply_quiet_setup_session!()
                    _with_tempdir() do proj
                        _project!(proj)
                        tree = joinpath(state_dir, "host1", "tree")
                        @test isdir(tree)
                        previous = DistSSHRun._LAST_SHIP[]
                        active = DistSSHRun._SHIP_LAYOUT_ACTIVE[]
                        try
                            failed = DistSSHRun.ship_project_to_hosts!(
                                ["host1"], proj, "/home/distsshkit/app"; confirm = false,
                            )
                            @test any(hr -> !hr.ok, failed.host_results)
                            @test isdir(tree)
                        finally
                            _restore_ship!(previous, active)
                        end
                    end
                end
            end
        finally
            DistSSHRun.set_kit_noninteractive!(prev_ni)
            DistSSHRun.set_kit_verbosity!(prev_verb)
        end
    end
end
