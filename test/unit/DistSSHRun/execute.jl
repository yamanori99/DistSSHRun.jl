using Test

# Oracle: dispatcher only (plus detached `:go`, which is out-of-process).
# `execute!(:drive, …)` includes a driver into `Main` and lives in
# `integration/drive/execute.jl` (after `api.jl`, which is the first
# in-process `drive!` and owns the warn-overwrite check).

@testset "execute!" begin
    @testset "_detached_julia_project" begin
        kit = pkgdir(DistSSHRun)
        @test kit !== nothing
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"NoKitHere\"\n")
            @test !DistSSHRun._project_tree_has_distsshkit(proj)
            @test DistSSHRun._detached_julia_project(proj) == kit
            write(
                joinpath(proj, "Project.toml"),
                """
                name = "BogusTopLevel"
                DistSSHRun = "not-a-dep"
                """,
            )
            @test !DistSSHRun._project_tree_has_distsshkit(proj)
            @test DistSSHRun._detached_julia_project(proj) == kit
            write(
                joinpath(proj, "Project.toml"),
                """
                name = "HasKitDep"
                [deps]
                DistSSHRun = "b568025c-2759-4ef1-8b14-17d00e2cd000"
                """,
            )
            @test DistSSHRun._project_tree_has_distsshkit(proj)
            @test DistSSHRun._detached_julia_project(proj) == proj
            @test DistSSHRun._detached_m_package(proj) == "DistSSHRun"
            write(
                joinpath(proj, "Project.toml"),
                """
                name = "HasMetaDep"
                [deps]
                DistSSHKit = "ceec0504-c968-4be5-b215-667cae0e8f81"
                """,
            )
            @test DistSSHRun._project_tree_has_distsshkit(proj)
            @test DistSSHRun._detached_julia_project(proj) == proj
            @test DistSSHRun._detached_m_package(proj) == "DistSSHKit"
        end
        _with_tempdir() do proj
            # DistSSHRun only transitive (e.g. via DistSSHQueue [deps]): the
            # Manifest is a flat graph and does not mark this direct, so
            # `-m DistSSHRun` cannot load from here (#372).
            write(joinpath(proj, "Project.toml"), "name = \"QueueOnly\"\n")
            write(
                joinpath(proj, "Manifest.toml"),
                """
                manifest_format = "2.0"
                [deps.DistSSHRun]
                uuid = "b568025c-2759-4ef1-8b14-17d00e2cd000"
                """,
            )
            @test !DistSSHRun._project_tree_has_distsshkit(proj)
            @test DistSSHRun._detached_julia_project(proj) == kit
        end
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"JunkManifest\"\n")
            write(joinpath(proj, "Manifest.toml"), "not = [ toml")
            @test !DistSSHRun._project_tree_has_distsshkit(proj)
            @test DistSSHRun._detached_julia_project(proj) == kit
        end
    end

    @testset "_remove_kit_pid_file" begin
        _with_tempdir() do d
            pid_path = joinpath(d, "kit.pid")
            write(pid_path, "4242")
            DistSSHRun._remove_kit_pid_file(99, d, nothing)
            @test isfile(pid_path)
            DistSSHRun._remove_kit_pid_file(4242, d, nothing)
            @test !isfile(pid_path)
            write(pid_path, "4242\nold-start\n")
            DistSSHRun._remove_kit_pid_file(4242, d, nothing)
            @test !isfile(pid_path)
        end
        _with_tempdir() do d
            proc = run(
                pipeline(
                    ignorestatus(`$(Base.julia_cmd()) --startup-file=no -e nothing`);
                    stdout = devnull,
                    stderr = devnull,
                );
                wait = false,
            )
            wait(proc)
            DistSSHRun._write_detached_kit_pid_file!(proc, d, nothing; run_dir = d)
            @test !isfile(joinpath(d, "kit.pid"))
        end
    end

    @testset "kit_pid_file_running" begin
        _with_tempdir() do d
            @test DistSSHRun.kit_pid_file_running(d) === false
            me = getpid()
            write(joinpath(d, "kit.pid"), string(me, '\n'))
            @test DistSSHRun.kit_pid_file_running(d) === true
            st = DistSSHRun.kit_process_start_key(me)
            if st !== nothing
                write(joinpath(d, "kit.pid"), string(me, '\n', st, '\n'))
                @test DistSSHRun.kit_pid_file_running(d) === true
                write(joinpath(d, "kit.pid"), string(me, '\n', "not-this-start", '\n'))
                @test DistSSHRun.kit_pid_file_running(d) === false
            end
            rec = DistSSHRun._parse_kit_pid_text("7\nboot\n")
            @test rec.pid == 7
            @test rec.start == "boot"
        end
    end

    @testset "kit_result_from_dir" begin
        _with_tempdir() do d
            @test DistSSHRun.kit_result_from_dir(d) === nothing
            DistSSHRun._write_kit_result_file(
                DistSSHRun.KitRunResult(
                    false, :drive, d, nothing, "drive", 42,
                )
            )
            got = DistSSHRun.kit_result_from_dir(d)
            @test got isa DistSSHRun.KitRunResult
            @test got.ok === false
            @test got.kind === :drive
            @test got.failed_step == "drive"
            @test got.exit_code == 42
            @test got.output_dir == d
            @test got.log_dir === nothing
            @test got.hosts == DistSSHRun.HostRunResult[]
            DistSSHRun._write_kit_result_file(
                DistSSHRun.KitRunResult(
                    false, :drive, d, nothing, "drive", 1,
                    [
                        DistSSHRun.HostRunResult("h1", true),
                        DistSSHRun.HostRunResult("h2", false, ErrorException("boom")),
                    ],
                )
            )
            with_hosts = DistSSHRun.kit_result_from_dir(d)
            @test length(with_hosts.hosts) == 2
            @test with_hosts.hosts[1] == DistSSHRun.HostRunResult("h1", true, nothing)
            @test with_hosts.hosts[2].host == "h2"
            @test with_hosts.hosts[2].ok === false
            @test with_hosts.hosts[2].error == "boom"
            @test DistSSHRun.HostRunResult("h2", false, "boom").error == "boom"
            DistSSHRun._write_kit_result_file(
                DistSSHRun.KitRunResult(
                    true, :ride, d, nothing, nothing, 0,
                )
            )
            ride_got = DistSSHRun.kit_result_from_dir(d)
            @test ride_got.kind === :ride
            @test ride_got.ok
            write(joinpath(d, "kit.result"), "not toml {")
            @test DistSSHRun.kit_result_from_dir(d) === nothing
        end
    end

    @testset "drive_host_status" begin
        @test DistSSHRun._probe_drive_host(Int[]) === :left
        @test DistSSHRun._probe_drive_host([999999]) === :left
        @test DistSSHRun._probe_drive_host([1]) === :alive
        DistSSHRun._clear_drive_host_worker_ids!()
        _with_tempdir() do d
            @test DistSSHRun.drive_host_status(d) == DistSSHRun.DriveHostStatus[]
            DistSSHRun._write_joined_drive_host_status!(["h1", "h2"], d, nothing)
            got = DistSSHRun.drive_host_status(d)
            @test length(got) == 2
            @test got[1].host == "h1"
            @test got[1].state === :joined
            @test got[1].last_seen === nothing
            DistSSHRun._register_drive_host_worker_ids!("h1", [1])
            DistSSHRun._register_drive_host_worker_ids!("h2", [999999])
            DistSSHRun._refresh_drive_host_status_file!(d, nothing; now = 1.5)
            live = DistSSHRun.drive_host_status(d)
            by = Dict(r.host => r for r in live)
            @test by["h1"].state === :alive
            @test by["h1"].last_seen == 1.5
            @test by["h2"].state === :left
            DistSSHRun._mark_drive_hosts_collect_pending!(d, nothing; now = 2.0)
            pending = DistSSHRun.drive_host_status(d)
            by2 = Dict(r.host => r for r in pending)
            @test by2["h1"].state === :collect_pending
            @test by2["h2"].state === :left
            @test DistSSHRun._drive_hosts_that_left() == ["h2"]
            @test DistSSHRun._drive_parent_worker_count() == 0
        end
        DistSSHRun._clear_drive_host_worker_ids!()
        DistSSHRun._register_drive_host_worker_ids!("h1", [1])
        _with_tempdir() do d
            DistSSHRun._start_drive_host_status_monitor!(d, nothing)
            @test DistSSHRun._drive_host_status_monitor_active()
            @test_throws ArgumentError DistSSHRun._start_drive_host_status_monitor!(d, nothing)
            DistSSHRun._stop_drive_host_status_monitor!()
            DistSSHRun._start_drive_host_status_monitor!(d, nothing)
            DistSSHRun._stop_drive_host_status_monitor!()
            DistSSHRun._start_drive_host_status_monitor!(d, nothing)
            t = DistSSHRun.DRIVE_HOST_STATUS_TASK[]
            @test t isa Task
            sleep(0.05)
            schedule(t::Task, InterruptException(); error = true)
            sleep(0.3)
            @test DistSSHRun._drive_host_status_monitor_active()
            DistSSHRun._stop_drive_host_status_monitor!()
        end
        DistSSHRun._clear_drive_host_worker_ids!()
    end

    @testset "allocate_output_dir" begin
        _with_tempdir() do project
            d1 = DistSSHRun.allocate_output_dir(:go, "batch.jl"; project)
            @test isdir(d1)
            @test occursin(joinpath(".distsshkit", "go"), d1)
            @test startswith(basename(d1), "batch_")
            d2 = DistSSHRun.allocate_output_dir(:drive, "run.jl"; project, job_id = "q1")
            @test isdir(d2)
            @test occursin(joinpath(".distsshkit", "drive"), d2)
            @test occursin("_q1", basename(d2))
            d3 = DistSSHRun.allocate_output_dir(:go, "batch.jl"; project)
            @test isdir(d3)
            @test d1 != d3
            d_ride = DistSSHRun.allocate_output_dir(:ride, "map.jl"; project)
            @test isdir(d_ride)
            @test occursin(joinpath(".distsshkit", "ride"), d_ride)
            err_kind = try
                DistSSHRun.allocate_output_dir(:pipeline, "x.jl"; project)
                nothing
            catch e
                e
            end
            @test err_kind isa ArgumentError
            err_id = try
                DistSSHRun.allocate_output_dir(:go, "x.jl"; project, job_id = "bad id")
                nothing
            catch e
                e
            end
            @test err_id isa ArgumentError
            taken = DistSSHRun.allocate_output_dir(:go, "same.jl"; project)
            again = DistSSHRun._mkdir_unique!(taken)
            @test again != taken
            @test isdir(again)
            @test startswith(basename(again), basename(taken))
        end
    end

    @testset "_ensure_drive_output_env!" begin
        _with_tempdir() do project
            script = joinpath(project, "job.jl")
            write(script, "")
            withenv("DISTRIBUTED_OUTPUT_DIR" => nothing) do
                d = DistSSHRun._ensure_drive_output_env!(script; project = project)
                @test isdir(d)
                @test startswith(basename(d), "job_")
                @test occursin(joinpath(".distsshkit", "drive"), d)
                @test ENV["DISTRIBUTED_OUTPUT_DIR"] == d
                @test DistSSHRun._ensure_drive_output_env!(script; project = project) == d
            end
            explicit = joinpath(project, "out")
            withenv("DISTRIBUTED_OUTPUT_DIR" => explicit) do
                got = DistSSHRun._ensure_drive_output_env!(script; project = project)
                @test got == DistSSHRun.canonical_local_path(explicit)
            end
        end
    end

    @testset "allocate_run_dir" begin
        _with_tempdir() do project
            script = joinpath(project, "job.jl")
            write(script, "")
            d1 = DistSSHRun.allocate_run_dir(:drive, script; project)
            @test isdir(d1)
            @test occursin(joinpath(".distsshkit", "runs", "drive"), d1)
            @test startswith(basename(d1), "job_")
            d2 = DistSSHRun.allocate_run_dir(:go, "batch.jl"; project, job_id = "q1")
            @test occursin(joinpath(".distsshkit", "runs", "go"), d2)
            @test occursin("_q1", basename(d2))
            @test DistSSHRun.read_kit_run_toml(d1) === nothing
            DistSSHRun.write_kit_run_toml!(
                d1;
                kind = :drive,
                output_dir = joinpath(project, "out"),
                result = DistSSHRun.KitRunResult(true, :drive, joinpath(project, "out"), nothing, nothing, 0),
            )
            raw = DistSSHRun.read_kit_run_toml(d1)
            @test raw isa AbstractDict
            @test raw["kind"] == "drive"
            @test raw["ok"] === true
            @test raw["schema"] == 1
            @test occursin("out", String(raw["output_dir"]))
        end

        _with_tempdir() do project
            ro = joinpath(project, "ro")
            mkpath(ro)
            script = joinpath(ro, "job.jl")
            write(script, "")
            chmod(ro, 0o555)
            try
                d = DistSSHRun.allocate_run_dir(:go, script; project)
                @test isdir(d)
                @test occursin(joinpath(".distsshkit", "runs", "go"), d)
                @test startswith(d, DistSSHRun.canonical_local_path(project))
                @test !startswith(d, DistSSHRun.canonical_local_path(ro))
            finally
                chmod(ro, 0o755)
            end
        end
    end

    @testset "_execute_detached_dirs drive unique" begin
        _with_tempdir() do project
            script = joinpath(project, "job.jl")
            write(script, "")
            run_a = DistSSHRun.allocate_run_dir(:drive, script; project)
            run_b = DistSSHRun.allocate_run_dir(:drive, script; project)
            withenv("DISTRIBUTED_OUTPUT_DIR" => nothing) do
                a, la = DistSSHRun._execute_detached_dirs(
                    :drive, project, script, nothing, nothing, true, run_a,
                )
                b, lb = DistSSHRun._execute_detached_dirs(
                    :drive, project, script, nothing, nothing, true, run_b,
                )
                @test a === nothing
                @test b === nothing
                @test la == DistSSHRun.canonical_local_path(run_a)
                @test lb == DistSSHRun.canonical_local_path(run_b)
                _, nolog = DistSSHRun._execute_detached_dirs(
                    :drive, project, script, nothing, nothing, false, run_a,
                )
                @test nolog === nothing
            end
            custom = joinpath(project, "fixed")
            mkpath(custom)
            c, lc = DistSSHRun._execute_detached_dirs(
                :drive, project, script, custom, nothing, true, run_a,
            )
            @test c == DistSSHRun.canonical_local_path(custom)
            @test lc == DistSSHRun.canonical_local_path(run_a)
            inherited = joinpath(project, "from_env")
            withenv("DISTRIBUTED_OUTPUT_DIR" => inherited) do
                e, le = DistSSHRun._execute_detached_dirs(
                    :drive, project, script, nothing, nothing, true, run_a,
                )
                @test e == DistSSHRun.canonical_local_path(inherited)
                @test le == DistSSHRun.canonical_local_path(run_a)
            end
        end
    end

    @testset "execute_detached_accepts" begin
        @test DistSSHRun.execute_detached_accepts(:quiet; kind = :go)
        @test DistSSHRun.execute_detached_accepts(:quiet; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:job_id; kind = :go)
        @test DistSSHRun.execute_detached_accepts(:job_id; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:output_dir; kind = :go)
        @test DistSSHRun.execute_detached_accepts(:output_dir; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:log_dir; kind = :drive)
        @test !DistSSHRun.execute_detached_accepts(:log_dir; kind = :go)
        @test DistSSHRun.execute_detached_accepts(:skip_hash_check; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:mem_headroom; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:parent_gb; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:repeat; kind = :go)
        @test !DistSSHRun.execute_detached_accepts(:repeat; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:workers; kind = :drive)
        @test !DistSSHRun.execute_detached_accepts(:mem_headroom; kind = :go)
        @test !DistSSHRun.execute_detached_accepts(:parent_gb; kind = :go)
        @test !DistSSHRun.execute_detached_accepts(:gb_per_worker; kind = :go)
        @test !DistSSHRun.execute_detached_accepts(:workers; kind = :go)
        @test !DistSSHRun.execute_detached_accepts(:plan; kind = :go)
        @test !DistSSHRun.execute_detached_accepts(:plan; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:spi_check; kind = :ride)
        @test !DistSSHRun.execute_detached_accepts(:gb_per_worker; kind = :ride)
        @test !DistSSHRun.execute_detached_accepts(:mem_headroom; kind = :ride)
        @test DistSSHRun.execute_detached_accepts(:output_dir; kind = :ride)
        @test !DistSSHRun.execute_detached_accepts(:repeat; kind = :ride)
        @test !DistSSHRun.execute_detached_accepts(:sync_script; kind = :ride)
        @test !DistSSHRun.execute_detached_accepts(:log_dir; kind = :ride)
        @test !DistSSHRun.execute_detached_accepts(:require_all_hosts; kind = :ride)
        @test !DistSSHRun.execute_detached_accepts(:spi_check; kind = :go)
        @test !DistSSHRun.execute_detached_accepts(:spi_check; kind = :drive)
        err = try
            DistSSHRun.execute_detached_accepts(:quiet; kind = :pipeline)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(":go, :drive, or :ride", sprint(showerror, err))
    end

    @testset "detached drive argv mem_headroom" begin
        argv = DistSSHRun._execute_detached_argv(
            :drive, "job.jl", ["parent:1"], String[];
            output_dir = "/tmp/out",
            log_dir = nothing,
            sync = nothing,
            julia = nothing,
            quiet = true,
            verbosity = nothing,
            hosts_file = nothing,
            enable_log = false,
            package = nothing,
            require_all_hosts = false,
            skip_hash_check = true,
            mem_headroom = 0.5,
            parent_gb = 0.2,
        )
        @test "--mem-headroom" in argv
        @test "0.5" in argv
        @test "--parent-gb" in argv
        @test "0.2" in argv
        @test "--best-effort" in argv
        @test !("--require-all-hosts" in argv)
        argv0 = DistSSHRun._execute_detached_argv(
            :drive, "job.jl", ["parent:1"], String[];
            output_dir = "/tmp/out",
            log_dir = nothing,
            sync = nothing,
            julia = nothing,
            quiet = true,
            verbosity = nothing,
            hosts_file = nothing,
            enable_log = false,
            package = nothing,
            require_all_hosts = false,
            skip_hash_check = true,
        )
        @test !("--mem-headroom" in argv0)
        @test !("--parent-gb" in argv0)
        @test "--best-effort" in argv0
        argvw = DistSSHRun._execute_detached_argv(
            :drive, "job.jl", ["child:host1"], String[];
            output_dir = "/tmp/out",
            log_dir = nothing,
            sync = nothing,
            julia = nothing,
            quiet = true,
            verbosity = nothing,
            hosts_file = nothing,
            enable_log = false,
            package = nothing,
            require_all_hosts = false,
            skip_hash_check = true,
            workers = 4,
        )
        @test "--workers" in argvw
        @test "4" in argvw
        @test "--best-effort" in argvw
        argv_rep = DistSSHRun._execute_detached_argv(
            :go, "job.jl", String[], String[];
            output_dir = "/tmp/out",
            log_dir = nothing,
            sync = nothing,
            julia = nothing,
            quiet = true,
            verbosity = nothing,
            hosts_file = nothing,
            enable_log = false,
            package = nothing,
            require_all_hosts = nothing,
            skip_hash_check = true,
            repeat = 100,
        )
        @test "--repeat" in argv_rep
        @test "100" in argv_rep
        @test !("--mem-headroom" in argv_rep)
        @test !("--gb-per-worker" in argv_rep)
        @test !("--probe" in argv_rep)
        argv_strict = DistSSHRun._execute_detached_argv(
            :drive, "job.jl", ["child:host1"], String[];
            output_dir = "/tmp/out",
            log_dir = nothing,
            sync = nothing,
            julia = nothing,
            quiet = true,
            verbosity = nothing,
            hosts_file = nothing,
            enable_log = false,
            package = nothing,
            require_all_hosts = true,
            skip_hash_check = true,
        )
        @test "--require-all-hosts" in argv_strict
        @test !("--best-effort" in argv_strict)
        @test_throws ArgumentError DistSSHRun._execute_detached_argv(
            :drive, "job.jl", ["child:host1"], String[];
            output_dir = "/tmp/out",
            log_dir = nothing,
            sync = nothing,
            julia = nothing,
            quiet = true,
            verbosity = nothing,
            hosts_file = nothing,
            enable_log = false,
            package = nothing,
            require_all_hosts = 0,
            skip_hash_check = true,
        )
        @test_throws ArgumentError DistSSHRun._execute_detached_argv(
            :drive, "job.jl", ["child:host1"], String[];
            output_dir = "/tmp/out",
            log_dir = nothing,
            sync = nothing,
            julia = nothing,
            quiet = true,
            verbosity = nothing,
            hosts_file = nothing,
            enable_log = false,
            package = nothing,
            require_all_hosts = nothing,
            skip_hash_check = true,
        )
        argv_ride = DistSSHRun._execute_detached_argv(
            :ride, "job.jl", ["parent:2"], String[];
            output_dir = "/tmp/out",
            log_dir = nothing,
            sync = nothing,
            julia = nothing,
            quiet = true,
            verbosity = nothing,
            hosts_file = nothing,
            enable_log = true,
            package = nothing,
            require_all_hosts = true,
            skip_hash_check = true,
            spi_check = false,
        )
        @test argv_ride[1] == "ride"
        @test !("--spi-check" in argv_ride)
        @test "--no-spi-check" in argv_ride
        @test !("--gb-per-worker" in argv_ride)
        @test "--output-dir" in argv_ride
        argv_ride_spi = DistSSHRun._execute_detached_argv(
            :ride, "job.jl", ["parent:2"], String[];
            output_dir = "/tmp/out",
            log_dir = nothing,
            sync = nothing,
            julia = nothing,
            quiet = true,
            verbosity = nothing,
            hosts_file = nothing,
            enable_log = true,
            package = nothing,
            require_all_hosts = true,
            skip_hash_check = true,
            spi_check = true,
        )
        @test "--spi-check" in argv_ride_spi
        @test !("--no-spi-check" in argv_ride_spi)
    end

    @testset "execute_kwargs_from_parsed" begin
        go = DistSSHRun.parse_go_args(
            [
                "--progress", "--julia", "/opt/julia/bin/julia",
                "--output-dir", "my_runs", "--sync", "child:h1:1", "job.jl", "8",
            ]
        )
        gkw = DistSSHRun.execute_kwargs_from_parsed(go; kind = :go)
        @test gkw[:verbosity] === :progress
        @test gkw[:julia] == "/opt/julia/bin/julia"
        @test gkw[:output_dir] == "my_runs"
        @test gkw[:sync] === :sync
        @test gkw[:args] == ["8"]
        @test !haskey(gkw, :hosts_file)
        @test !haskey(gkw, :workers)
        @test DistSSHRun.host_tokens(go; kind = :go) == ["child:h1:1"]
        @test Set(keys(gkw)) == Set(
            [
                :output_dir, :args, :julia, :quiet, :verbosity, :sync,
            ]
        )
        go_r = DistSSHRun.parse_go_args(["--repeat", "8", "job.jl"])
        @test DistSSHRun.execute_kwargs_from_parsed(go_r; kind = :go)[:repeat] == 8

        ride = DistSSHRun.parse_ride_args(
            [
                "--no-spi-check", "parent:2", "job.jl",
            ]
        )
        rkw = DistSSHRun.execute_kwargs_from_parsed(ride; kind = :ride)
        @test rkw[:spi_check] === false
        @test !haskey(rkw, :gb_per_worker)
        @test DistSSHRun.host_tokens(ride; kind = :ride) == ["parent:2"]
        @test !haskey(rkw, :sync)

        hosts_file = _sample_hosts_file()
        drive = DistSSHRun.parse_drive_args(
            [
                "--no-log", "--package", "Foo", "--mem-headroom", "0.5",
                "--parent-gb", "0.2", "--workers", "4",
                "--hosts-file", hosts_file, "s.jl",
            ]
        )
        dkw = DistSSHRun.execute_kwargs_from_parsed(drive; kind = :drive)
        @test dkw[:enable_log] === false
        @test dkw[:package] == "Foo"
        @test dkw[:mem_headroom] == 0.5
        @test dkw[:parent_gb] == 0.2
        @test dkw[:workers] == 4
        @test !haskey(dkw, :hosts_file)
        @test DistSSHRun.host_tokens(drive; kind = :drive) ==
            ["parent:4", "child:host-a:1", "child:host-b:4"]
        bare = DistSSHRun.parse_drive_args(["child:host1:1", "s.jl"])
        @test !haskey(DistSSHRun.execute_kwargs_from_parsed(bare; kind = :drive), :workers)
        errk = try
            DistSSHRun.execute_kwargs_from_parsed(go; kind = :pipeline)
            nothing
        catch e
            e
        end
        @test errk isa ArgumentError
        @test occursin(":go, :drive, or :ride", sprint(showerror, errk))
    end

    @testset "kind not :go / :drive / :ride" begin
        err = try
            DistSSHRun.execute!(:pipeline, "job.jl", String[])
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(":go, :drive, or :ride", sprint(showerror, err))
    end

    @testset "detached rejects unknown / yes=false" begin
        err = try
            DistSSHRun.execute!(:go, "job.jl", ["parent:1"]; detached = true, plan = nothing)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("does not accept keyword :plan", sprint(showerror, err))

        err2 = try
            DistSSHRun.execute!(:go, "job.jl", ["parent:1"]; detached = true, yes = false)
            nothing
        catch e
            e
        end
        @test err2 isa ArgumentError
        @test occursin("yes=true", sprint(showerror, err2))

        err3 = try
            DistSSHRun.execute!(:go, "job.jl", ["parent:1"]; detached = true, log_dir = "x")
            nothing
        catch e
            e
        end
        @test err3 isa ArgumentError
        @test occursin(":log_dir", sprint(showerror, err3))

        err4 = try
            DistSSHRun.execute!(:go, "job.jl", ["parent:1"]; detached = true, skip_hash_check = true)
            nothing
        catch e
            e
        end
        @test err4 isa ArgumentError
        @test occursin(":skip_hash_check", sprint(showerror, err4))

        err5 = try
            DistSSHRun.execute!(:go, "job.jl", ["parent:1"]; detached = true, workers = 4)
            nothing
        catch e
            e
        end
        @test err5 isa ArgumentError
        @test occursin(":workers", sprint(showerror, err5))

        err6 = try
            DistSSHRun.execute!(:drive, "job.jl", ["parent:1"]; detached = true, spi_check = false)
            nothing
        catch e
            e
        end
        @test err6 isa ArgumentError
        @test occursin(":spi_check", sprint(showerror, err6))
    end

    @testset ":go dispatch" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"ExecuteGo\"\n")
            script = joinpath(proj, "job.jl")
            write(
                script, """
                out = get(ENV, "DISTRIBUTED_OUTPUT_DIR", ".")
                mkpath(out)
                write(joinpath(out, "args.txt"), join(ARGS, ","))
                """
            )
            result = DistSSHRun.execute!(
                :go,
                script,
                ["parent:1"];
                project = proj,
                args = ["8"],
                quiet = true,
                yes = true,
            )
            @test result isa DistSSHRun.KitRunResult
            @test result.kind === :go
            @test result.ok
            @test result.exit_code == 0
            @test result.output_dir !== nothing
            @test read(joinpath(result.output_dir, "parent", "args.txt"), String) == "8"
        end
    end

    @testset ":go detached" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"ExecuteGoDetached\"\n")
            script = joinpath(proj, "job.jl")
            write(
                script, """
                out = get(ENV, "DISTRIBUTED_OUTPUT_DIR", ".")
                mkpath(out)
                write(joinpath(out, "args.txt"), join(ARGS, ","))
                """
            )
            mktemp() do _, out_io
                mktemp() do _, err_io
                    kp = DistSSHRun.execute!(
                        :go,
                        script,
                        ["parent:1"];
                        detached = true,
                        project = proj,
                        args = ["8"],
                        quiet = true,
                        stdout = out_io,
                        stderr = err_io,
                    )
                    pid_path = joinpath(kp.output_dir, "kit.pid")
                    if process_running(kp.process)
                        t0 = time()
                        while !isfile(pid_path) && process_running(kp.process) && (time() - t0) < 5
                            sleep(0.05)
                        end
                        if isfile(pid_path)
                            rec = DistSSHRun._read_kit_pid_record(kp.output_dir)
                            @test rec !== nothing
                            @test rec.pid == getpid(kp.process)
                        end
                    end
                    result = wait(kp)
                    flush(out_io)
                    flush(err_io)
                    @test kp isa DistSSHRun.KitProcess
                    @test kp.kind === :go
                    @test kp.log_dir === nothing
                    @test kp.output_dir !== nothing
                    @test result isa DistSSHRun.KitRunResult
                    @test result.kind === :go
                    @test result.ok
                    @test result.exit_code == 0
                    @test result.output_dir == kp.output_dir
                    @test result.log_dir === nothing
                    @test read(joinpath(result.output_dir, "parent", "args.txt"), String) == "8"
                    @test !isfile(pid_path)
                    @test !isfile(joinpath(result.output_dir, "kit.out"))
                    @test !isfile(joinpath(result.output_dir, "kit.err"))
                    recovered = DistSSHRun.kit_result_from_dir(result.output_dir)
                    @test recovered isa DistSSHRun.KitRunResult
                    @test recovered.ok
                    @test recovered.kind === :go
                    @test recovered.exit_code == 0
                    @test recovered.output_dir == result.output_dir
                    @test result.ok == recovered.ok
                    @test result.failed_step === recovered.failed_step
                end
            end
        end
    end

    @testset ":go detached job_id" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"ExecuteGoJobId\"\n")
            script = joinpath(proj, "job.jl")
            ran = joinpath(proj, "RAN")
            write(
                script, """
                out = get(ENV, "DISTRIBUTED_OUTPUT_DIR", ".")
                mkpath(out)
                write($(repr(ran)), "yes")
                """
            )
            mktemp() do _, out_io
                mktemp() do _, err_io
                    kp = DistSSHRun.execute!(
                        :go,
                        script,
                        ["parent:1"];
                        detached = true,
                        project = proj,
                        verbosity = :progress,
                        job_id = "q-1",
                        stdout = out_io,
                        stderr = err_io,
                    )
                    result = wait(kp)
                    @test result.ok
                    pid_path = joinpath(result.output_dir, "kit.pid")
                    @test !isfile(pid_path)
                    @test isfile(joinpath(result.output_dir, "kit.job"))
                    @test strip(read(joinpath(result.output_dir, "kit.job"), String)) == "q-1"
                    log_files = filter(f -> endswith(f, ".log"), readdir(result.output_dir))
                    @test !isempty(log_files)
                    log_body = read(joinpath(result.output_dir, first(log_files)), String)
                    @test occursin("job=q-1", log_body)
                    @test isfile(ran)
                end
            end
        end
    end

    @testset ":go detached default stdio files" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"ExecuteGoStdio\"\n")
            script = joinpath(proj, "job.jl")
            write(
                script, """
                out = get(ENV, "DISTRIBUTED_OUTPUT_DIR", ".")
                mkpath(out)
                """
            )
            kp = DistSSHRun.execute!(
                :go,
                script,
                ["parent:1"];
                detached = true,
                project = proj,
                quiet = true,
            )
            result = wait(kp)
            @test result.ok
            @test kp.run_dir !== nothing
            @test isfile(joinpath(kp.run_dir, "kit.out"))
            @test isfile(joinpath(kp.run_dir, "kit.err"))
        end
    end

    @testset "job_id charset / kit_job_eval_arg" begin
        withenv("DISTSSHKIT_JOB_ID" => nothing) do
            @test DistSSHRun.resolved_kit_job_id() === nothing
        end
        @test DistSSHRun.kit_job_eval_arg("q-1") == "--eval=#distsshkit-job:q-1"
        @test DistSSHRun.kit_job_mark_comment("q-1") == "#distsshkit-job:q-1"
        @test !occursin("include(", DistSSHRun.kit_job_eval_arg("q-1"))
        @test !occursin("ENV[", DistSSHRun.kit_job_eval_arg("q-1"))
        mktempdir() do d
            p = DistSSHRun.kit_write_job_mark_file(d, "q-1")
            @test basename(p) == "distsshkit-job:q-1"
            @test read(p, String) == "#distsshkit-job:q-1\n"
        end
        err = try
            DistSSHRun._parse_kit_job_id("has space")
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
    end

    @testset "wait timeout hung" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"WaitHung\"\n")
            script = joinpath(proj, "job.jl")
            write(
                script, """
                out = get(ENV, "DISTRIBUTED_OUTPUT_DIR", ".")
                mkpath(out)
                sleep(60)
                """
            )
            kp = DistSSHRun.execute!(
                :go,
                script,
                ["parent:1"];
                detached = true,
                project = proj,
                quiet = true,
            )
            hung = wait(kp; timeout = 0.4)
            @test hung.ok === false
            @test hung.failed_step == "hung"
            @test hung.exit_code == 124
            @test process_running(kp.process)
            killed = DistSSHRun.terminate!(kp; grace = 2)
            @test !process_running(kp.process)
            @test killed isa DistSSHRun.KitRunResult
        end
    end

    @testset "terminate! detached go" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"TerminateGo\"\n")
            script = joinpath(proj, "job.jl")
            write(
                script, """
                out = get(ENV, "DISTRIBUTED_OUTPUT_DIR", ".")
                mkpath(out)
                sleep(60)
                """
            )
            mktemp() do _, out_io
                mktemp() do _, err_io
                    kp = DistSSHRun.execute!(
                        :go,
                        script,
                        ["parent:1"];
                        detached = true,
                        project = proj,
                        verbosity = :progress,
                        job_id = "t-1",
                        stdout = out_io,
                        stderr = err_io,
                    )
                    result = DistSSHRun.terminate!(kp; grace = 2)
                    @test result isa DistSSHRun.KitRunResult
                    @test !process_running(kp.process)
                    @test result.kind === :go
                end
            end
        end
    end

    @testset "terminate! detached ride" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"TerminateRide\"\n")
            script = joinpath(proj, "job.jl")
            write(
                script, """
                sleep(60)
                """
            )
            mktemp() do _, out_io
                mktemp() do _, err_io
                    kp = DistSSHRun.execute!(
                        :ride,
                        script,
                        ["parent:1"];
                        detached = true,
                        project = proj,
                        verbosity = :progress,
                        job_id = "t-ride",
                        stdout = out_io,
                        stderr = err_io,
                    )
                    result = DistSSHRun.terminate!(kp; grace = 2)
                    @test result isa DistSSHRun.KitRunResult
                    @test !process_running(kp.process)
                    @test result.kind === :ride
                end
            end
        end
    end

    @testset "terminate_run! missing pid" begin
        _with_tempdir() do d
            r = DistSSHRun.terminate_run!(d; grace = 0)
            @test r isa DistSSHRun.KitRunResult
            @test r.ok === false
            @test r.failed_step == "terminated"
            @test r.kind === :go
        end
    end
end
