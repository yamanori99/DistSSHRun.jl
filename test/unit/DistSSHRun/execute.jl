using Test

function _must_run_toml(path::AbstractString)::AbstractDict
    raw = DistSSHRun.read_kit_run_toml(path)
    raw isa AbstractDict || error("run.toml missing at $(path)")
    return raw::AbstractDict
end

function _log_kw(record, key)
    for (k, v) in record.kwargs
        k === key && return v
    end
    return nothing
end

# Oracle: dispatcher only (plus detached `:go`, which is out-of-process).
# `execute!(:drive, …)` includes a driver into `Main` and lives in
# `integration/drive/execute.jl` (after `api.jl`, which is the first
# in-process `drive!` and owns the warn-overwrite check).

@testset "execute!" begin
    @testset "_detached_julia_project" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"NoKitHere\"\n")
            @test !DistSSHRun._project_tree_has_distsshkit(proj)
            err = try
                DistSSHRun._detached_julia_project(proj)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("does not list DistSSHKit or DistSSHRun", err.msg)
            write(
                joinpath(proj, "Project.toml"),
                """
                name = "BogusTopLevel"
                DistSSHRun = "not-a-dep"
                """,
            )
            @test !DistSSHRun._project_tree_has_distsshkit(proj)
            @test_throws ArgumentError DistSSHRun._detached_julia_project(proj)
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
            write(joinpath(proj, "Project.toml"), "name = \"DistSSHRun\"\n")
            @test DistSSHRun._project_tree_has_distsshkit(proj)
            @test DistSSHRun._detached_julia_project(proj) == proj
            @test DistSSHRun._detached_m_package(proj) == "DistSSHRun"
            write(joinpath(proj, "Project.toml"), "name = \"DistSSHKit\"\n")
            @test DistSSHRun._project_tree_has_distsshkit(proj)
            @test DistSSHRun._detached_julia_project(proj) == proj
            @test DistSSHRun._detached_m_package(proj) == "DistSSHKit"
        end
        _with_tempdir() do proj
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
            @test_throws ArgumentError DistSSHRun._detached_julia_project(proj)
        end
        _with_tempdir() do empty
            @test_throws ArgumentError DistSSHRun._detached_julia_project(empty)
        end
        _with_tempdir() do root
            job = joinpath(root, "job")
            mkpath(job)
            write(joinpath(job, "Project.toml"), "name = \"NoKitHere\"\n")
            @test DistSSHRun._detached_m_package(job) == "DistSSHRun"
            @test_throws ArgumentError DistSSHRun._detached_julia_project(job)
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
            @test rec !== nothing
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
            @test got.stop === nothing
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
            @test with_hosts !== nothing
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
            @test ride_got !== nothing
            @test ride_got.kind === :ride
            @test ride_got.ok
            write(joinpath(d, "kit.result"), "not toml {")
            @test DistSSHRun.kit_result_from_dir(d) === nothing
            stopped = DistSSHRun.KitRunResult(
                false, :go, d, nothing, "go", 1,
                DistSSHRun.HostRunResult[], String[], :within_grace,
            )
            @test stopped.stop === :within_grace
            @test_throws ArgumentError DistSSHRun.KitRunResult(
                false, :go, d, nothing, "go", 1,
                DistSSHRun.HostRunResult[], String[], :later,
            )
            DistSSHRun._write_kit_result_file(stopped; run_dir = nothing)
            again = DistSSHRun.kit_result_from_dir(d)
            @test again !== nothing
            @test again.stop === :within_grace
            @test occursin("within_grace", read(joinpath(d, "kit.result"), String))
            write(
                joinpath(d, "kit.result"),
                """
                ok = false
                kind = "go"
                exit_code = 1
                stop = "nope"
                """,
            )
            unknown = DistSSHRun.kit_result_from_dir(d)
            @test unknown !== nothing
            @test unknown.stop === nothing
            DistSSHRun.write_kit_run_toml!(
                d;
                kind = :go,
                result = DistSSHRun.KitRunResult(true, :go, d, nothing, nothing, 0),
            )
            before = DistSSHRun.read_kit_run_toml(d)
            @test before isa AbstractDict
            if before isa AbstractDict
                @test before["schema"] == 1
                @test !haskey(before, "stop")
            end
            DistSSHRun._stamp_run_toml_stop!(d, :sigkill)
            after = DistSSHRun.read_kit_run_toml(d)
            @test after isa AbstractDict
            if after isa AbstractDict
                @test after["schema"] == 1
                @test after["kind"] == "go"
                @test after["ok"] === true
                @test after["stop"] == "sigkill"
            end
            other = mktempdir()
            try
                write(joinpath(other, "run.toml"), "name = \"job\"\n")
                DistSSHRun._stamp_run_toml_stop!(other, :sigkill)
                @test read(joinpath(other, "run.toml"), String) == "name = \"job\"\n"
                write(joinpath(other, "run.toml"), "schema = 1\nkind = \"go\"\n")
                DistSSHRun._stamp_run_toml_stop!(other, :sigkill)
                @test !occursin("stop", read(joinpath(other, "run.toml"), String))
                out = joinpath(other, "out")
                mkpath(out)
                write(joinpath(out, "run.toml"), "name = \"artifact\"\n")
                DistSSHRun._persist_stop(
                    DistSSHRun.KitRunResult(false, :go, out, nothing, "go", 1),
                    :sigterm;
                    run_dir = nothing,
                )
                @test read(joinpath(out, "run.toml"), String) == "name = \"artifact\"\n"
                run_d = joinpath(other, "run")
                mkpath(run_d)
                DistSSHRun.write_kit_run_toml!(
                    run_d;
                    kind = :go,
                    result = DistSSHRun.KitRunResult(true, :go, out, nothing, nothing, 0),
                )
                DistSSHRun._write_kit_pid_file(getpid(), out, nothing; run_dir = run_d)
                @test DistSSHRun._run_dir_for_stop(out) ==
                    DistSSHRun.canonical_local_path(run_d)
                DistSSHRun._persist_stop(
                    DistSSHRun.KitRunResult(false, :go, out, nothing, "terminated", 1),
                    :sigterm;
                    run_dir = DistSSHRun._run_dir_for_stop(out),
                )
                stamped = DistSSHRun.read_kit_run_toml(run_d)
                @test stamped isa AbstractDict
                if stamped isa AbstractDict
                    @test stamped["stop"] == "sigterm"
                end
                @test read(joinpath(out, "run.toml"), String) == "name = \"artifact\"\n"
                stray = joinpath(other, "caller-run")
                mkpath(stray)
                DistSSHRun.write_kit_run_toml!(
                    stray;
                    kind = :go,
                    result = DistSSHRun.KitRunResult(true, :go, out, nothing, nothing, 0),
                )
                empty_out = joinpath(other, "empty-out")
                mkpath(empty_out)
                withenv(DistSSHRun.DISTSSHKIT_RUN_DIR_ENV => stray) do
                    @test DistSSHRun._run_dir_for_stop(empty_out) === nothing
                    @test DistSSHRun._run_dir_for_stop(run_d) ==
                        DistSSHRun.canonical_local_path(run_d)
                end
                blocked = joinpath(other, "blocked")
                mkpath(blocked)
                mkdir(joinpath(blocked, "kit.run_dir"))
                DistSSHRun._write_kit_pid_file(
                    getpid(),
                    blocked,
                    nothing;
                    run_dir = run_d,
                )
                @test !isfile(joinpath(blocked, "kit.pid"))
            finally
                rm(other; recursive = true, force = true)
            end
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
            other = mktempdir()
            try
                cd(other) do
                    withenv("DISTRIBUTED_COLLECT_DIRS" => "rel-out") do
                        DistSSHRun.write_kit_run_toml!(
                            d1;
                            kind = :drive,
                            project_root = project,
                        )
                        recorded = DistSSHRun.read_kit_run_toml(d1)
                        @test recorded !== nothing
                        @test recorded["collect_dirs"] == ["rel-out"]
                    end
                end
            finally
                rm(other; recursive = true, force = true)
            end
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
        @test !DistSSHRun.execute_detached_accepts(:mem_headroom; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:repeat; kind = :go)
        @test !DistSSHRun.execute_detached_accepts(:repeat; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:workers; kind = :drive)
        @test !DistSSHRun.execute_detached_accepts(:mem_headroom; kind = :go)
        @test !DistSSHRun.execute_detached_accepts(:parent_gb; kind = :go)
        @test !DistSSHRun.execute_detached_accepts(:gb_per_worker; kind = :go)
        @test !DistSSHRun.execute_detached_accepts(:workers; kind = :go)
        @test !DistSSHRun.execute_detached_accepts(:plan; kind = :go)
        @test !DistSSHRun.execute_detached_accepts(:plan; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:allow_external_symlinks; kind = :go)
        @test DistSSHRun.execute_detached_accepts(:allow_external_symlinks; kind = :drive)
        @test !DistSSHRun.execute_detached_accepts(:allow_external_symlinks; kind = :ride)
        @test DistSSHRun.execute_detached_accepts(:allow_mismatch; kind = :go)
        @test DistSSHRun.execute_detached_accepts(:allow_mismatch; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:allow_mismatch; kind = :ride)
        @test DistSSHRun.execute_detached_accepts(:snapshot; kind = :go)
        @test DistSSHRun.execute_detached_accepts(:snapshot; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:snapshot; kind = :ride)
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

    @testset "detached drive argv require-all-hosts" begin
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
        )
        @test !("--mem-headroom" in argv)
        @test "--best-effort" in argv
        @test !("--require-all-hosts" in argv)
        @test !("--allow-external-symlinks" in argv)
        argv_ext = DistSSHRun._execute_detached_argv(
            :go, "job.jl", ["child:h1:1"], String[];
            output_dir = nothing,
            log_dir = nothing,
            sync = :ship_tree,
            julia = nothing,
            quiet = true,
            verbosity = nothing,
            hosts_file = nothing,
            enable_log = false,
            package = nothing,
            require_all_hosts = true,
            skip_hash_check = true,
            allow_external_symlinks = true,
        )
        @test "--ship-tree" in argv_ext
        @test "--allow-external-symlinks" in argv_ext
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
        @test !("--allow-external-symlinks" in argv_ride)
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
        argv_snap = DistSSHRun._execute_detached_argv(
            :go, "job.jl", ["parent:1"], String[];
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
            snapshot = "20260101T000000Z-aaaaaa",
        )
        @test "--snapshot" in argv_snap
        @test "20260101T000000Z-aaaaaa" in argv_snap
        argv_root = DistSSHRun._execute_detached_argv(
            :go, "job.jl", ["parent:1"], String[];
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
            remote = "/tmp/App",
        )
        @test "--deploy-root" in argv_root
        @test "/tmp/App" in argv_root
        @test !("--remote-path" in argv_root)
    end

    @testset "execute_kwargs_from_parsed" begin
        go = DistSSHRun.parse_go_args(
            [
                "--progress", "--julia", "/opt/julia/bin/julia",
                "--output-dir", "my_runs", "--sync", "child:h1:1", "job.jl", "8",
            ]
        )
        gkw = DistSSHRun.execute_kwargs_from_parsed(go; kind = :go)
        @test !haskey(gkw, :snapshot)
        go_snap = DistSSHRun.parse_go_args(
            ["--snapshot", "20260101T000000Z-aaaaaa", "parent:1", "job.jl"],
        )
        gsnap = DistSSHRun.execute_kwargs_from_parsed(go_snap; kind = :go)
        @test gsnap[:snapshot] == "20260101T000000Z-aaaaaa"
        go_root = DistSSHRun.parse_go_args(
            ["--deploy-root", "/tmp/App", "parent:1", "job.jl"],
        )
        @test DistSSHRun.execute_kwargs_from_parsed(go_root; kind = :go)[:remote] == "/tmp/App"
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
        go_ext = DistSSHRun.parse_go_args(
            ["--ship-tree", "--allow-external-symlinks", "child:h1:1", "job.jl"],
        )
        @test DistSSHRun.execute_kwargs_from_parsed(go_ext; kind = :go)[:allow_external_symlinks] ===
            true
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
                "--no-log", "--package", "Foo", "--workers", "4",
                "--hosts-file", hosts_file, "s.jl",
            ]
        )
        dkw = DistSSHRun.execute_kwargs_from_parsed(drive; kind = :drive)
        @test dkw[:enable_log] === false
        @test dkw[:package] == "Foo"
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
            write(joinpath(proj, "Manifest.toml"), "# lock\n")
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
            _write_job_with_distsshrun!(proj)
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
                    _, kp = _capture_detached_env_log() do
                        DistSSHRun.execute!(
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
                    end
                    out_dir = kp.output_dir
                    @test out_dir !== nothing
                    pid_path = joinpath(out_dir, "kit.pid")
                    if process_running(kp.process)
                        t0 = time()
                        while !isfile(pid_path) && process_running(kp.process) && (time() - t0) < 5
                            sleep(0.05)
                        end
                        if isfile(pid_path)
                            rec = DistSSHRun._read_kit_pid_record(out_dir)
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
            _write_job_with_distsshrun!(proj)
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
                    _, kp = _capture_detached_env_log() do
                        DistSSHRun.execute!(
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
                    end
                    result = wait(kp)
                    @test result.ok
                    out_dir = result.output_dir
                    @test out_dir !== nothing
                    pid_path = joinpath(out_dir, "kit.pid")
                    @test !isfile(pid_path)
                    @test isfile(joinpath(out_dir, "kit.job"))
                    @test strip(read(joinpath(out_dir, "kit.job"), String)) == "q-1"
                    log_files = filter(f -> endswith(f, ".log"), readdir(out_dir))
                    @test !isempty(log_files)
                    log_body = read(joinpath(out_dir, first(log_files)), String)
                    @test occursin("job=q-1", log_body)
                    @test isfile(ran)
                end
            end
        end
    end

    @testset ":go detached default stdio files" begin
        _with_tempdir() do proj
            _write_job_with_distsshrun!(proj)
            script = joinpath(proj, "job.jl")
            write(
                script, """
                out = get(ENV, "DISTRIBUTED_OUTPUT_DIR", ".")
                mkpath(out)
                """
            )
            _, kp = _capture_detached_env_log() do
                DistSSHRun.execute!(
                    :go,
                    script,
                    ["parent:1"];
                    detached = true,
                    project = proj,
                    quiet = true,
                )
            end
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
            _write_job_with_distsshrun!(proj)
            script = joinpath(proj, "job.jl")
            write(
                script, """
                out = get(ENV, "DISTRIBUTED_OUTPUT_DIR", ".")
                mkpath(out)
                sleep(60)
                """
            )
            _, kp = _capture_detached_env_log() do
                DistSSHRun.execute!(
                    :go,
                    script,
                    ["parent:1"];
                    detached = true,
                    project = proj,
                    quiet = true,
                )
            end
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
            _write_job_with_distsshrun!(proj)
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
                    _, kp = _capture_detached_env_log() do
                        DistSSHRun.execute!(
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
                    end
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
            _write_job_with_distsshrun!(proj)
            script = joinpath(proj, "job.jl")
            write(
                script, """
                sleep(60)
                """
            )
            mktemp() do _, out_io
                mktemp() do _, err_io
                    _, kp = _capture_detached_env_log() do
                        DistSSHRun.execute!(
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
                    end
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
            @test r.stop === nothing
            err = try
                DistSSHRun.terminate_run!(d; interrupt_grace = -1)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            err_nan = try
                DistSSHRun.terminate_run!(d; interrupt_grace = NaN)
                nothing
            catch e
                e
            end
            @test err_nan isa ArgumentError
        end
        _with_tempdir() do tmp
            out = joinpath(tmp, "out")
            run_d = joinpath(tmp, "run")
            mkpath(out)
            mkpath(run_d)
            write(
                joinpath(out, "kit.run_dir"),
                DistSSHRun.canonical_local_path(run_d) * "\n",
            )
            DistSSHRun._write_kit_result_file(
                DistSSHRun.KitRunResult(false, :go, run_d, nothing, "collect", 7);
                run_dir = run_d,
            )
            r = DistSSHRun.terminate_run!(out; grace = 0)
            @test r.failed_step == "collect"
            @test r.exit_code == 7
            @test r.kind === :go
        end
    end

    @testset "interrupt_grace default and DISTSSHKIT_WAIT_SIGINT_GRACE" begin
        # Headroom for slow NFS / x86 / WSL2. The 30s default is not computed from this.
        margin = 10.0
        @test DistSSHRun._INTERRUPT_GRACE_DEFAULT_S >=
            Float64(DistSSHRun.DistSSHBase._SSH_CONNECT_TIMEOUT_S) +
            DistSSHRun._INTERRUPT_SETTLE_S +
            DistSSHRun._HEARTBEAT_STOP_S +
            DistSSHRun._RMPROCS_WAITFOR_S +
            margin
        @test DistSSHRun._SIGNAL_KILL_WAIT_S == 1.0
        withenv("DISTSSHKIT_WAIT_SIGINT_GRACE" => nothing) do
            @test DistSSHRun._resolve_interrupt_grace(nothing) ==
                DistSSHRun._INTERRUPT_GRACE_DEFAULT_S
            @test DistSSHRun._resolve_interrupt_grace(nothing) ==
                DistSSHRun.DistSSHBase.wait_seconds(:sigint_grace, 30.0)
        end
        withenv("DISTSSHKIT_WAIT_SIGINT_GRACE" => "4.5") do
            @test DistSSHRun._resolve_interrupt_grace(nothing) == 4.5
            @test DistSSHRun._resolve_interrupt_grace(0) == 0.0
            @test DistSSHRun._resolve_interrupt_grace(1) == 1.0
        end
        withenv("DISTSSHKIT_WAIT_SIGINT_GRACE" => "-1") do
            @test_throws ArgumentError DistSSHRun._resolve_interrupt_grace(nothing)
            @test DistSSHRun._resolve_interrupt_grace(2) == 2.0
        end
        withenv("DISTSSHKIT_WAIT_SIGINT_GRACE" => "NaN") do
            @test_throws ArgumentError DistSSHRun._resolve_interrupt_grace(nothing)
        end
        withenv("DISTSSHKIT_WAIT_SIGINT_GRACE" => "Inf") do
            @test_throws ArgumentError DistSSHRun._resolve_interrupt_grace(nothing)
        end
        @test_throws ArgumentError DistSSHRun._resolve_interrupt_grace(-0.1)
        @test_throws ArgumentError DistSSHRun._resolve_interrupt_grace(NaN)
        @test_throws ArgumentError DistSSHRun._resolve_interrupt_grace(Inf)
    end

    @testset "signal ladder stop" begin
        function sh(script)::Base.Process
            proc = run(
                pipeline(`sh -c $script`; stdout = devnull, stderr = devnull);
                wait = false,
            )
            if proc isa Base.Process
                return proc
            end
            error("expected one process")
        end
        function ladder(script; interrupt_grace, grace)
            # `touch` runs after `trap`, so the signal is not delivered
            # before the ignore is installed.
            d = mktempdir()
            ready = joinpath(d, "ready")
            quoted = "'" * replace(ready, "'" => "'\\''") * "'"
            p = sh(script * "; touch $quoted; while true; do :; done")
            try
                t0 = time()
                while !isfile(ready) && process_running(p) && (time() - t0) < 5
                    sleep(0.02)
                end
                @assert isfile(ready)
                return DistSSHRun._signal_ladder!(
                    p; interrupt_grace = interrupt_grace, grace = grace,
                )
            finally
                process_running(p) && kill(p, Base.SIGKILL)
                try
                    wait(p)
                catch
                end
                rm(d; recursive = true, force = true)
            end
        end
        @test DistSSHRun._signal_ladder!(0; interrupt_grace = 1, grace = 1) === nothing
        dead = sh("exit 0")
        wait(dead)
        @test DistSSHRun._signal_ladder!(dead; interrupt_grace = 1, grace = 1) === nothing
        @test ladder("trap '' INT"; interrupt_grace = 0.3, grace = 1) === :sigterm
        @test ladder("trap '' INT TERM"; interrupt_grace = 0.2, grace = 0.2) === :sigkill
        @test ladder("true"; interrupt_grace = 2, grace = 1) === :within_grace
        @test ladder("true"; interrupt_grace = 0, grace = 1) === :no_sigint
    end

    @testset "terminate! sends one SIGINT" begin
        _with_tempdir() do dir
            ready = joinpath(dir, "ready")
            countp = joinpath(dir, "count")
            script = joinpath(dir, "count.jl")
            # `ready` is created inside the `try`. The parent signals as soon
            # as that file exists. Julia 1.13 turns SIGINT into
            # `InterruptException` at the next safepoint, so a file written
            # before this `try` (and before this toplevel thunk finishes
            # compiling) is killed with count 0. A blocking `sleep` is not
            # that safepoint on macOS; `GC.safepoint` is. Julia 1.14 throws
            # `CancellationRequest` from `sleep` and does not throw at a
            # safepoint. Count that once, then `pause`, or `sleep` throws
            # again and the count runs away.
            write(
                script,
                """
                Base.exit_on_sigint(false)
                const n = Ref(0)
                atexit() do
                    open($(repr(countp)), "w") do io
                        print(io, n[])
                    end
                end
                if isdefined(Base, :CancellationRequest)
                    const CR = getglobal(Base, :CancellationRequest)
                    while true
                        try
                            open($(repr(ready)), "w") do io
                                print(io, "1")
                            end
                            sleep(60)
                        catch e
                            e isa InterruptException || e isa CR || rethrow()
                            n[] += 1
                            e isa CR && break
                        end
                    end
                    while true
                        try
                            ccall(:pause, Cint, ())
                        catch e
                            e isa InterruptException || e isa CR || rethrow()
                            n[] += 1
                        end
                    end
                else
                    while true
                        try
                            open($(repr(ready)), "w") do io
                                print(io, "1")
                            end
                            t0 = time()
                            while time() - t0 < 60
                                GC.safepoint()
                            end
                        catch e
                            e isa InterruptException || rethrow()
                            n[] += 1
                            break
                        end
                    end
                    while true
                        try
                            ccall(:pause, Cint, ())
                        catch e
                            e isa InterruptException || rethrow()
                            n[] += 1
                        end
                    end
                end
                """,
            )
            julia = joinpath(Sys.BINDIR, Base.julia_exename())
            proc = run(
                pipeline(
                    `$julia --startup-file=no --compile=min $script`;
                    stdout = devnull,
                    stderr = devnull,
                );
                wait = false,
            )
            kp = DistSSHRun.KitProcess(proc; kind = :go, output_dir = dir)
            try
                t0 = time()
                while !isfile(ready) && (time() - t0) < 60
                    process_running(proc) || break
                    sleep(0.05)
                end
                @test isfile(ready)
                stopped = DistSSHRun.terminate!(kp; interrupt_grace = 0.4, grace = 2)
                @test isfile(countp)
                @test read(countp, String) == "1"
                @test stopped.stop === :sigterm
                recorded = DistSSHRun.kit_result_from_dir(dir)
                @test recorded !== nothing
                @test recorded.stop === :sigterm
            finally
                process_running(proc) && kill(proc, Base.SIGKILL)
            end
        end
    end

    @testset "detached execute! refuses a non-empty output_dir" begin
        _with_tempdir() do project
            script = joinpath(project, "job.jl")
            write(script, "println(\"no\")\n")
            dirty = joinpath(project, "out")
            mkdir(dirty)
            write(joinpath(dirty, "old.txt"), "x\n")
            err = try
                DistSSHRun.execute!(
                    :go, script, String[];
                    detached = true,
                    output_dir = dirty,
                    project = project,
                    yes = true,
                )
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            err isa ArgumentError || error("expected ArgumentError")
            @test occursin("old.txt", err.msg)
            @test occursin("Omit output_dir or pass an empty directory.", err.msg)
            @test !occursin("--help", err.msg)
            @test !isdir(joinpath(project, ".distsshkit", "runs"))
        end
    end

    @testset "result_run_dir on KitProcess" begin
        julia = joinpath(Sys.BINDIR, Base.julia_exename())
        proc = run(
            pipeline(`$julia --startup-file=no -e nothing`; stdout = devnull, stderr = devnull);
            wait = true,
        )
        bare = DistSSHRun.KitProcess(proc; kind = :go)
        @test DistSSHRun.result_run_dir(bare) === nothing
        @test_throws MethodError DistSSHRun.result_content_tree_hash(bare)
        @test_throws MethodError DistSSHRun.result_remote_run_id(bare)
        _with_tempdir() do run_dir
            held = DistSSHRun.KitProcess(proc; kind = :drive, run_dir = run_dir)
            @test DistSSHRun.result_run_dir(held) == run_dir
        end
    end

    @testset "wait(::KitProcess) uses shell_status" begin
        function _wait_code(proc)
            return _with_tempdir() do dir
                kp = DistSSHRun.KitProcess(proc; kind = :go, output_dir = dir)
                result = wait(kp)
                return result
            end
        end
        for (code, ok) in ((0, true), (3, false), (255, false))
            proc = run(ignorestatus(`sh -c "exit $code"`); wait = true)
            result = _wait_code(proc)
            @test result.ok == ok
            @test result.exit_code == code
            ok || @test result.failed_step == "go"
        end
        for (sig, status) in ((Base.SIGTERM, 143), (Base.SIGKILL, 137))
            proc = run(ignorestatus(`sleep 30`); wait = false)
            process_running(proc) || error("sleep exited before $(sig)")
            kill(proc, sig)
            wait(proc)
            result = _wait_code(proc)
            @test result.ok == false
            @test result.exit_code == status
            @test result.failed_step == "go"
        end
    end

    @testset "detached launch policy" begin
        parent = Dict{String, String}(
            "PATH" => "/usr/bin",
            "HOME" => "/home/me",
            "JULIA_DEPOT_PATH" => "/depot",
            "DISTSSHKIT_SSH_TUNNEL" => "0",
            "DISTRIBUTED_OUTPUT_DIR" => "/out",
            "AWS_SECRET_ACCESS_KEY" => "sek",
            "JULIA_PROJECT" => "/queue",
            "JULIA_LOAD_PATH" => "@",
            "EMPTY_SKIP" => "",
            "JULIA_WORKER_COOKIE" => "abc",
            "JULIA_NUM_THREADS" => "8",
            "OPENBLAS_NUM_THREADS" => "8",
            "OPENBLAS_DEFAULT_NUM_THREADS" => "4",
            "CUSTOM_JOB_PATH" => "kept",
            "DISTSSHQUEUE_STORE" => "/q",
            "DISTSSHKIT_FOO_TOKEN" => "t",
            "http_proxy" => "http://user:pass@proxy:8080",
            "https_proxy" => "http://proxy:8080",
            "LC_ALL" => "C",
            "DISTSSHKIT_BLAS_THREADS" => "3",
        )
        built = DistSSHRun._detached_child_env(
            parent, Dict{String, String}();
            threads = 1,
            env_allow = nothing,
            env = nothing,
            launch_dir = "/work",
            source = nothing,
        )
        @test built.env["PATH"] == "/usr/bin"
        @test built.env["HOME"] == "/home/me"
        @test built.env["JULIA_DEPOT_PATH"] == "/depot"
        @test built.env["DISTSSHKIT_SSH_TUNNEL"] == "0"
        @test built.env["DISTRIBUTED_OUTPUT_DIR"] == "/out"
        @test built.env["LC_ALL"] == "C"
        @test built.env["https_proxy"] == "http://proxy:8080"
        @test built.env["OPENBLAS_NUM_THREADS"] == "3"
        @test built.env["OMP_NUM_THREADS"] == "3"
        @test built.env["MKL_NUM_THREADS"] == "3"
        @test built.env["GOTO_NUM_THREADS"] == "3"
        @test built.env["VECLIB_MAXIMUM_THREADS"] == "3"
        @test !haskey(built.env, "OPENBLAS_DEFAULT_NUM_THREADS")
        @test !haskey(built.env, "JULIA_NUM_THREADS")
        @test !haskey(built.env, "AWS_SECRET_ACCESS_KEY")
        @test !haskey(built.env, "JULIA_PROJECT")
        @test !haskey(built.env, "JULIA_LOAD_PATH")
        @test !haskey(built.env, "EMPTY_SKIP")
        @test !haskey(built.env, "JULIA_WORKER_COOKIE")
        @test !haskey(built.env, "CUSTOM_JOB_PATH")
        @test !haskey(built.env, "DISTSSHQUEUE_STORE")
        @test !haskey(built.env, "DISTSSHKIT_FOO_TOKEN")
        @test !haskey(built.env, "http_proxy")
        @test built.threads == "1"
        @test built.env["DISTSSHKIT_LAUNCH_THREADS"] == "1"
        @test built.env["DISTSSHKIT_LAUNCH_DIR"] == "/work"
        @test built.env["DISTSSHKIT_SKIP_GLOBAL_WORKER_PKILL"] == "1"
        @test "AWS_SECRET_ACCESS_KEY" in built.dropped
        @test "JULIA_LOAD_PATH" in built.dropped
        @test "JULIA_WORKER_COOKIE" in built.dropped
        @test "http_proxy" in built.dropped
        @test "EMPTY_SKIP" ∉ built.dropped
        @test isempty(built.sensitive)

        allowed = DistSSHRun._detached_child_env(
            parent, Dict{String, String}();
            threads = 1,
            env_allow = ["AWS_SECRET_ACCESS_KEY", "http_proxy"],
            env = nothing,
            launch_dir = "/work",
            source = nothing,
        )
        @test allowed.env["AWS_SECRET_ACCESS_KEY"] == "sek"
        @test allowed.env["http_proxy"] == "http://user:pass@proxy:8080"
        @test "AWS_SECRET_ACCESS_KEY" in allowed.sensitive
        @test "AWS_SECRET_ACCESS_KEY" ∉ allowed.dropped
        @test "http_proxy" ∉ allowed.dropped

        wide = DistSSHRun._detached_child_env(
            parent, Dict{String, String}();
            threads = 1,
            env_allow = :all,
            env = nothing,
            launch_dir = "/work",
            source = nothing,
        )
        @test wide.env["HOME"] == "/home/me"
        @test wide.env["CUSTOM_JOB_PATH"] == "kept"
        @test !haskey(wide.env, "JULIA_NUM_THREADS")
        @test !haskey(wide.env, "OPENBLAS_NUM_THREADS") || wide.env["OPENBLAS_NUM_THREADS"] == "3"
        @test wide.env["OPENBLAS_NUM_THREADS"] == "3"
        @test !haskey(wide.env, "AWS_SECRET_ACCESS_KEY")
        @test !haskey(wide.env, "JULIA_LOAD_PATH")
        @test !haskey(wide.env, "http_proxy")
        @test "JULIA_NUM_THREADS" in wide.dropped

        legacy = DistSSHRun._detached_child_env(
            parent, Dict{String, String}();
            threads = :unset,
            env_allow = :all,
            env = nothing,
            launch_dir = "/work",
            source = nothing,
        )
        @test legacy.threads == "unset"
        @test legacy.env["JULIA_NUM_THREADS"] == "8"
        @test legacy.env["OPENBLAS_NUM_THREADS"] == "8"
        @test !haskey(legacy.env, "OPENBLAS_DEFAULT_NUM_THREADS") ||
            legacy.env["OPENBLAS_DEFAULT_NUM_THREADS"] == "4"
        @test legacy.env["OPENBLAS_DEFAULT_NUM_THREADS"] == "4"
        @test !haskey(legacy.env, "JULIA_LOAD_PATH")
        @test !haskey(legacy.env, "AWS_SECRET_ACCESS_KEY")

        named = DistSSHRun._detached_child_env(
            parent, Dict{String, String}();
            threads = :unset,
            env_allow = ["JULIA_NUM_THREADS", "DISTSSHKIT_FOO_TOKEN"],
            env = Dict("TZ" => "UTC", "HOME" => "", "BRAND_NEW" => "1"),
            launch_dir = "/work",
            source = nothing,
        )
        @test named.env["JULIA_NUM_THREADS"] == "8"
        @test named.env["DISTSSHKIT_FOO_TOKEN"] == "t"
        @test "DISTSSHKIT_FOO_TOKEN" in named.sensitive
        @test named.env["TZ"] == "UTC"
        @test named.env["BRAND_NEW"] == "1"
        @test !haskey(named.env, "HOME")
        @test "HOME" in named.dropped

        @test_throws ArgumentError DistSSHRun._detached_child_env(
            parent, Dict{String, String}();
            threads = 1,
            env_allow = ["JULIA_LOAD_PATH"],
            env = nothing,
            launch_dir = "/work",
            source = nothing,
        )
        @test_throws ArgumentError DistSSHRun._detached_child_env(
            parent, Dict{String, String}();
            threads = 1,
            env_allow = ["JULIA_NUM_THREADS"],
            env = nothing,
            launch_dir = "/work",
            source = nothing,
        )
        @test_throws ArgumentError DistSSHRun._detached_thread_flag(true)
        @test_throws ArgumentError DistSSHRun._detached_thread_flag(0)
        @test_throws ArgumentError DistSSHRun._detached_thread_flag("0,1")
        @test DistSSHRun._detached_thread_flag(4) == "4"
        @test DistSSHRun._detached_thread_flag("auto") == "auto"
        @test DistSSHRun._detached_thread_flag("4,1") == "4,1"
        @test DistSSHRun._detached_thread_flag("1,0") == "1,0"
        @test DistSSHRun._detached_threads_from_counts(1, 0) == "1"
        @test DistSSHRun._detached_threads_from_counts(4, 1) == "4,1"
        @test DistSSHRun._detached_thread_flag(:inherit) == DistSSHRun._launch_thread_spec()
        @test DistSSHRun.execute_detached_accepts(:threads; kind = :go)
        @test DistSSHRun.execute_detached_accepts(:threads; kind = :ride)
        @test DistSSHRun.execute_detached_accepts(:threads; kind = :drive)
        @test DistSSHRun.execute_detached_accepts(:dir; kind = :go)
        @test DistSSHRun.execute_detached_accepts(:env_allow; kind = :ride)
        @test DistSSHRun.execute_detached_accepts(:env; kind = :drive)

        session = (quiet = false, verbosity = nothing)
        parsed = (
            cli_session = session,
            script_args = String[],
            output_dir = nothing,
            julia = nothing,
            allow_mismatch = Symbol[],
            sync = nothing,
            repeat = nothing,
            allow_external_symlinks = false,
            threads = 4,
            dir = "/work",
            env_allow = ["FOO"],
            env = Dict{String, String}("TZ" => "UTC"),
        )
        kw = DistSSHRun.execute_kwargs_from_parsed(parsed; kind = :go)
        @test kw[:threads] == 4
        @test kw[:dir] == "/work"
        @test kw[:env_allow] == ["FOO"]
        @test kw[:env] == Dict{String, String}("TZ" => "UTC")
        go = DistSSHRun.parse_go_args(["job.jl"])
        @test !haskey(DistSSHRun.execute_kwargs_from_parsed(go; kind = :go), :threads)
        @test !haskey(DistSSHRun.execute_kwargs_from_parsed(go; kind = :go), :dir)
        @test !haskey(DistSSHRun.execute_kwargs_from_parsed(go; kind = :go), :env_allow)
        @test !haskey(DistSSHRun.execute_kwargs_from_parsed(go; kind = :go), :env)

        @test_throws ArgumentError DistSSHRun.execute!(:go, "job.jl"; threads = 4)
        @test_throws ArgumentError DistSSHRun.execute!(:go, "job.jl"; dir = "/tmp")
        @test_throws ArgumentError DistSSHRun.execute!(:go, "job.jl"; env_allow = String[])
        @test_throws ArgumentError DistSSHRun.execute!(
            :go, "job.jl"; env = Dict("A" => "B"),
        )

        julia = joinpath(Sys.BINDIR, Base.julia_exename())
        proc = run(
            pipeline(
                `$julia --startup-file=no -e nothing`;
                stdout = devnull,
                stderr = devnull,
            );
            wait = true,
        )
        bare = DistSSHRun.KitProcess(proc; kind = :go)
        bare_launch = DistSSHRun.detached_launch(bare)
        @test bare_launch.dir == ""
        @test bare_launch.threads == "unset"
        @test bare_launch.dropped == String[]
        @test bare_launch.sensitive == String[]

        _with_tempdir() do proj
            here = pwd()
            @test_throws ArgumentError DistSSHRun._detached_launch_dir(
                joinpath(proj, "missing"), proj,
            )
            @test DistSSHRun._detached_launch_dir(nothing, proj) ==
                DistSSHRun.canonical_local_path(realpath(proj))
            @test pwd() == here
            DistSSHRun.write_kit_run_toml!(proj; kind = :go, project_root = proj)
            plain = _must_run_toml(proj)
            @test plain["schema"] == 1
            @test !haskey(plain, "launch")
            withenv(
                "DISTSSHKIT_LAUNCH_THREADS" => "1",
                "DISTSSHKIT_LAUNCH_DIR" => proj,
                "DISTSSHKIT_LAUNCH_DROPPED" => "SECRET_TOKEN,ZZZ",
            ) do
                DistSSHRun.write_kit_run_toml!(proj; kind = :go, project_root = proj)
            end
            stamped = _must_run_toml(proj)
            @test stamped["schema"] == 1
            launch = stamped["launch"]::AbstractDict
            @test launch["threads"] == "1"
            @test launch["dir"] == "."
            @test String.(launch["dropped"]) == ["SECRET_TOKEN", "ZZZ"]
        end
    end

    @testset "dropped env log" begin
        logs, _ = _capture_detached_env_log(; min_level = Test.Logging.Debug) do
            DistSSHRun._log_detached_dropped!(["SECRET_TOKEN", "ZZZ"])
        end
        infos = filter(r -> r.level == Test.Logging.Info, logs)
        @test length(infos) == 1
        @test occursin(
            "dropped 2 environment variables not on the allowlist",
            infos[1].message,
        )
        @test !occursin("SECRET_TOKEN", infos[1].message)
        @test !occursin("ZZZ", infos[1].message)
        debugs = filter(r -> r.level == Test.Logging.Debug, logs)
        @test length(debugs) == 1
        @test _log_kw(debugs[1], :names) == "SECRET_TOKEN, ZZZ"
        empty_logs, _ = _capture_detached_env_log(; min_level = Test.Logging.Debug) do
            DistSSHRun._log_detached_dropped!(String[])
        end
        @test isempty(empty_logs)
    end

    @testset "detached launch spawn" begin
        _with_tempdir() do proj
            _write_job_with_distsshrun!(proj)
            script = joinpath(proj, "job.jl")
            marker = joinpath(proj, "launch.txt")
            write(
                script,
                """
                open($(repr(marker)), "w") do io
                    println(io, "pwd=", pwd())
                    println(io, "n=", Threads.nthreads())
                    println(io, "ni=", Threads.nthreads(:interactive))
                    println(io, "secret=", haskey(ENV, "SECRET_TOKEN"))
                    println(io, "home=", haskey(ENV, "HOME"))
                    println(io, "custom=", get(ENV, "CUSTOM_JOB_PATH", ""))
                end
                """,
            )
            parent_pwd = pwd()
            withenv(
                "SECRET_TOKEN" => "nope",
                "CUSTOM_JOB_PATH" => "kept",
            ) do
                logs, kp = _capture_detached_env_log(; min_level = Test.Logging.Debug) do
                    DistSSHRun.execute!(
                        :go,
                        script,
                        ["parent:1"];
                        detached = true,
                        project = proj,
                        quiet = true,
                        stdout = devnull,
                        stderr = devnull,
                    )
                end
                result = wait(kp)
                @test result.ok
                report = DistSSHRun.detached_launch(kp)
                @test report.threads == "1"
                @test report.dir == DistSSHRun._detached_launch_dir(nothing, proj)
                @test "SECRET_TOKEN" in report.dropped
                @test "CUSTOM_JOB_PATH" in report.dropped
                @test "HOME" ∉ report.dropped
                raw = _must_run_toml(kp.run_dir::AbstractString)
                @test raw["schema"] == 1
                launch = raw["launch"]::AbstractDict
                @test launch["threads"] == "1"
                @test "SECRET_TOKEN" in String.(launch["dropped"])
                infos = filter(r -> r.level == Test.Logging.Info, logs)
                @test length(infos) == 1
                @test occursin(
                    "dropped $(length(report.dropped)) environment variables not on the allowlist",
                    infos[1].message,
                )
                @test !occursin("SECRET_TOKEN", infos[1].message)
                @test !occursin("nope", infos[1].message)
                debugs = filter(r -> r.level == Test.Logging.Debug, logs)
                @test length(debugs) == 1
                names = String(_log_kw(debugs[1], :names))
                @test occursin("SECRET_TOKEN", names)
                @test !occursin("nope", names)
            end
            @test pwd() == parent_pwd
            body = read(marker, String)
            @test occursin(
                "pwd=$(DistSSHRun._detached_launch_dir(nothing, proj))",
                body,
            )
            @test occursin("n=1", body)
            @test occursin("ni=0", body)
            @test occursin("secret=false", body)
            @test occursin("home=true", body)
            @test occursin("custom=", body)
            @test !occursin("custom=kept", body)

            withenv(
                "SECRET_TOKEN" => "nope",
                "CUSTOM_JOB_PATH" => "kept",
            ) do
                _, kp = _capture_detached_env_log() do
                    DistSSHRun.execute!(
                        :go,
                        script,
                        ["parent:1"];
                        detached = true,
                        project = proj,
                        quiet = true,
                        stdout = devnull,
                        stderr = devnull,
                        dir = parent_pwd,
                        threads = :unset,
                        env_allow = :all,
                    )
                end
                result = wait(kp)
                @test result.ok
                report = DistSSHRun.detached_launch(kp)
                @test report.threads == "unset"
                @test report.dir == DistSSHRun._detached_launch_dir(parent_pwd, proj)
                @test "CUSTOM_JOB_PATH" ∉ report.dropped
                @test "SECRET_TOKEN" in report.dropped
            end
            @test pwd() == parent_pwd
            restored = read(marker, String)
            @test occursin(
                "pwd=$(DistSSHRun._detached_launch_dir(parent_pwd, proj))",
                restored,
            )
            @test occursin("custom=kept", restored)
            @test occursin("secret=false", restored)

            marker_snap = joinpath(proj, "launch_snap.txt")
            script_snap = joinpath(proj, "job_snap.jl")
            write(
                script_snap,
                """
                open($(repr(marker_snap)), "w") do io
                    println(io, "ok")
                end
                """,
            )
            _, kp_snap = _capture_detached_env_log() do
                DistSSHRun.execute!(
                    :go,
                    script_snap,
                    ["parent:1"];
                    detached = true,
                    project = proj,
                    quiet = true,
                    snapshot = "20260101T000000Z-aaaaaa",
                    stdout = devnull,
                    stderr = devnull,
                )
            end
            result_snap = wait(kp_snap)
            @test result_snap.ok
            @test isfile(marker_snap)
        end
    end

end
