using Test

function _sigint_sa_handler()::Ptr{Cvoid}
    buf = zeros(UInt8, 256)
    rc = GC.@preserve buf ccall(
        :sigaction, Cint, (Cint, Ptr{Cvoid}, Ptr{UInt8}), Cint(2), C_NULL, buf,
    )
    rc == 0 || error("sigaction SIGINT failed: $rc")
    return GC.@preserve buf unsafe_load(Ptr{Ptr{Cvoid}}(pointer(buf)))
end

@testset "drive API" begin
    @testset "parse_worker_tokens" begin
        p = DistSSHRun.parse_worker_tokens(["parent:2", "child:host-a:4", "child:host-b"])
        @test p.parent_workers == 2
        @test !p.parent_autosize
        @test p.child_workers == Dict("host-a" => 4)
        @test p.child_auto == ["host-b"]
        @test p.child_hosts == ["host-a", "host-b"]
        @test DistSSHRun.worker_tokens_fully_specified(p) == false

        fixed = DistSSHRun.parse_worker_tokens(["parent:2", "child:h1:1"])
        @test DistSSHRun.worker_tokens_fully_specified(fixed)
        let plan = DistSSHRun.worker_plan_from_tokens(["parent:2", "child:h1:1"])
            @test plan.parent_workers == 2
            @test plan.child_workers == Dict("h1" => 1)
        end
        err = try
            DistSSHRun.worker_plan_from_tokens(["child:h1"])
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(":N", sprint(showerror, err))

        @test_throws ArgumentError DistSSHRun.parse_worker_tokens(["parent:1", "parent:2"])

        auto = DistSSHRun.parse_worker_tokens(["parent", "child:h1:3"])
        @test auto.parent_autosize
        @test auto.parent_workers == 0
        @test auto.child_workers == Dict("h1" => 3)
        @test DistSSHRun.child_hosts_from_tokens(["parent:2", "child:h1", "child:h2:4"]) == ["h1", "h2"]
        @test_throws ArgumentError DistSSHRun.require_counted_placement_tokens(["parent"])
        @test DistSSHRun.require_counted_placement_tokens(["parent:1"]) === nothing

        let kw = DistSSHRun.ParsedWorkerTokens(;
                parent_workers = 2,
                child_workers = Dict("h1" => 0x03),
                child_hosts = ["h1"],
                tokens = ["parent:2", "child:h1:3"],
            )
            @test kw.child_workers isa Dict{String, Int}
            @test kw.child_workers == Dict("h1" => 3)
            @test kw.child_auto == String[]
            @test !kw.parent_autosize
        end

        @test_throws ArgumentError DistSSHRun.worker_plan_from_tokens(["parent"])
        plan = DistSSHRun.worker_plan_from_tokens(["parent:2"])
        @test plan.parent_workers == 2
        @test isempty(plan.child_workers)
    end

    @testset "DistSSHSession" begin
        _with_tempdir() do tmp
            withenv("DISTSSH_HOSTS_FILE" => "") do
                session = DistSSHRun.DistSSHSession(project = tmp, workers = ["child:host-a", "child:host-b:4"])
                @test session.project == abspath(tmp)
                @test session.hosts == ["host-a", "host-b"]
                @test session.tokens == ["child:host-a", "child:host-b:4"]
                @test session.remote === nothing
                @test session.yes == true
            end
        end
    end

    @testset "drive_host_specs" begin
        plan = DistSSHRun.WorkerPlan(2, Dict("host-a" => 4, "host-b" => 0))
        @test DistSSHRun.drive_host_specs(plan) == ["parent:2", "child:host-a:4"]
    end

    @testset "apply_session_env!" begin
        _with_tempdir() do tmp
            delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
            session = DistSSHRun.DistSSHSession(
                project = tmp,
                workers = ["child:host-a"],
                remote = "/remote/App.jl",
                quiet = true,
                yes = true,
            )
            DistSSHRun.apply_session_env!(session)
            @test ENV["DISTRIBUTED_PROJECT_ROOT"] == abspath(tmp)
            @test !haskey(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
            @test DistSSHRun.session_remote_root(session) == "/remote/App.jl"
            @test DistSSHRun.kit_output_quiet()
            @test DistSSHRun.kit_noninteractive()
        end
        _with_tempdir() do tmp
            delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
            tilde = DistSSHRun.DistSSHSession(
                project = tmp,
                workers = ["child:host-a"],
                remote = "~/jobs/abc",
                quiet = true,
                yes = true,
            )
            DistSSHRun.apply_session_env!(tilde)
            @test !haskey(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
            @test DistSSHRun.session_remote_root(tilde) == "~/jobs/abc"
        end
        _with_tempdir() do tmp
            ambient = DistSSHRun.DistSSHSession(
                project = tmp,
                workers = ["child:host-a"],
                yes = true,
            )
            with_kit_verbosity(:progress) do
                DistSSHRun.apply_session_env!(ambient)
                @test DistSSHRun.kit_verbosity() === :progress
                @test ambient.verbosity === :progress
            end
        end
        _with_tempdir() do tmp
            delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
            a = DistSSHRun.DistSSHSession(
                project = tmp, workers = ["child:host-a"],
                remote = "/remote/A", quiet = true, yes = true,
            )
            DistSSHRun.apply_session_env!(a)
            b = DistSSHRun.DistSSHSession(
                project = tmp, workers = ["child:host-b"], quiet = true, yes = true,
            )
            default = DistSSHRun.remote_deploy_root(tmp)
            @test DistSSHRun.session_remote_root(b) == default
            @test DistSSHRun.session_remote_root(b) != "/remote/A"
            ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = "/caller/Keep"
            DistSSHRun.apply_session_env!(
                DistSSHRun.DistSSHSession(
                    project = tmp, workers = ["child:h"],
                    remote = "/session/Override", quiet = true, yes = true,
                ),
            )
            @test ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] == "/caller/Keep"
            err = try
                DistSSHRun.apply_session_env!(
                    DistSSHRun.DistSSHSession(
                        project = tmp, workers = ["child:h"],
                        remote = "/after/Error", quiet = true, yes = true,
                    ),
                )
                throw(ErrorException("force-fail"))
            catch e
                e
            end
            @test err isa ErrorException
            @test ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] == "/caller/Keep"
            delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
            DistSSHRun.apply_session_env!(
                DistSSHRun.DistSSHSession(
                    project = tmp, workers = ["child:h"],
                    remote = "/was/absent", quiet = true, yes = true,
                ),
            )
            @test !haskey(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
        end
        delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
        delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
        DistSSHRun.set_kit_output_quiet!(false)
        DistSSHRun.set_kit_noninteractive!(false)
    end

    @testset "overlapping in-process kit runs are refused" begin
        DistSSHRun._with_kit_inproc_run!(:setup) do
            t = @async begin
                try
                    DistSSHRun._acquire_kit_inproc_run!(:sync)
                    nothing
                catch e
                    e
                end
            end
            err = fetch(t)
            @test err isa ArgumentError
            @test occursin("overlapping in-process", sprint(showerror, err))
        end
        # Nested same-task is allowed.
        DistSSHRun._with_kit_inproc_run!(:pipeline) do
            DistSSHRun._with_kit_inproc_run!(:drive) do
                @test DistSSHRun._kit_inproc_run_kind() === :pipeline
            end
        end
    end

    @testset "session_remote_root / session_size_hosts" begin
        _with_tempdir() do tmp
            session = DistSSHRun.DistSSHSession(
                project = tmp,
                workers = ["child:h1:1"],
                remote = "/remote/App.jl",
                include_parent_for_size = true,
            )
            @test DistSSHRun.session_remote_root(session) == "/remote/App.jl"
            all_h, remotes = DistSSHRun.session_size_hosts(session)
            @test all_h == ["parent", "h1"]
            @test remotes == ["h1"]
            remote_only = DistSSHRun.DistSSHSession(project = tmp, workers = ["child:h1:1"])
            a2, r2 = DistSSHRun.session_size_hosts(remote_only)
            @test a2 == ["h1"]
            @test r2 == ["h1"]
        end
    end

    @testset "pipeline helpers" begin
        @test_throws MethodError DistSSHRun.PipelineConfig(;
            driver = "job.jl",
            workers = ["child:host-a"],
            sync = :ship_tree,
        )

        default_cfg = DistSSHRun.PipelineConfig(driver = "job.jl", workers = ["child:host-a"])
        default_session = DistSSHRun.kit_session_from_config(default_cfg)
        @test DistSSHRun.resolve_pipeline_collect(default_cfg, default_session)
        @test DistSSHRun.pipeline_skip_hash_check(default_cfg)
        @test default_cfg.yes == true
        @test DistSSHRun.kit_session_from_config(default_cfg).yes == true
        @test !DistSSHRun.pipeline_skip_hash_check(
            DistSSHRun.PipelineConfig(
                driver = "job.jl",
                workers = ["child:host-a"],
                skip_hash_check = false,
            ),
        )

        local_cfg = DistSSHRun.PipelineConfig(
            driver = "job.jl",
            workers = ["parent:2"],
            collect = false,
        )
        local_session = DistSSHRun.kit_session_from_config(local_cfg)
        @test !DistSSHRun.resolve_pipeline_collect(local_cfg, local_session)

        _with_tempdir() do tmp
            driver = joinpath(tmp, "job.jl")
            write(driver, "")
            od = joinpath(tmp, "my_out")
            cfg_od = DistSSHRun.PipelineConfig(driver = driver, output_dir = od)
            @test DistSSHRun.pipeline_collect_root(cfg_od) == abspath(od)
            dest = joinpath(tmp, "collect_here")
            cfg_path = DistSSHRun.PipelineConfig(driver = driver, collect = dest)
            @test DistSSHRun.pipeline_collect_root(cfg_path) == abspath(dest)
            withenv("DISTRIBUTED_OUTPUT_DIR" => joinpath(tmp, "env_out")) do
                cfg_env = DistSSHRun.PipelineConfig(driver = driver)
                @test DistSSHRun.pipeline_collect_root(cfg_env) ==
                    abspath(joinpath(tmp, "env_out"))
            end
            delete!(ENV, "DISTRIBUTED_OUTPUT_DIR")
            cfg_fallback = DistSSHRun.PipelineConfig(driver = driver)
            @test DistSSHRun.pipeline_collect_root(cfg_fallback) ==
                joinpath(dirname(abspath(driver)), "output")
        end

        withenv(
            "DRIVER" => "",
            "DISTSSH_HOSTS" => "",
            "DISTSSH_HOSTS_FILE" => "",
        ) do
            @test_throws ArgumentError DistSSHRun.pipeline_config_from_env()
        end
        withenv(
            "DRIVER" => "job.jl",
            "DISTSSH_QUIET" => "1",
            "DISTSSH_VERBOSE" => "1",
            "DISTSSH_PROGRESS" => nothing,
            "DISTSSH_HOSTS" => "",
            "DISTSSH_HOSTS_FILE" => "",
        ) do
            @test_throws ArgumentError DistSSHRun.pipeline_config_from_env()
        end

        cfg_jl = DistSSHRun.PipelineConfig(
            driver = "job.jl",
            workers = ["child:host-a"],
            julia = "/opt/julia/bin/julia",
        )
        @test cfg_jl.julia == "/opt/julia/bin/julia"
        @test DistSSHRun.PipelineConfig(driver = "job.jl", julia = "auto").julia === nothing
        @test DistSSHRun.PipelineConfig(driver = "job.jl", julia = "").julia === nothing
        @test_throws MethodError DistSSHRun.PipelineConfig(; driver = "job.jl", mem_headroom = 0.75)
        @test_throws MethodError DistSSHRun.PipelineConfig(; driver = "job.jl", parent_gb = 0.4)
    end

    @testset "drive_parsed_from_session sync / parity" begin
        _with_tempdir() do tmp
            script = joinpath(tmp, "job.jl")
            write(script, "")
            session = DistSSHRun.DistSSHSession(project = tmp, workers = ["child:host-a"])

            parsed = DistSSHRun.drive_parsed_from_session(session, script)
            @test parsed.worker_include == false
            err_ss = try
                DistSSHRun.drive_parsed_from_session(session, script; sync_script = true)
                nothing
            catch e
                e
            end
            @test err_ss isa ArgumentError
            @test occursin("sync_script= was removed", err_ss.msg)
            @test DistSSHRun.drive_parsed_from_session(
                session, script; worker_include = true,
            ).worker_include == true
            @test parsed.skip_hash_check == true
            @test parsed.hint_surface === :api
            @test parsed.julia === nothing
            @test parsed.require_all_hosts
            @test DistSSHRun.drive_parsed_from_session(
                session, script; require_all_hosts = false,
            ).require_all_hosts == false

            parsed_jl = DistSSHRun.drive_parsed_from_session(
                session,
                script;
                julia = "/opt/julia/bin/julia",
            )
            @test parsed_jl.julia == "/opt/julia/bin/julia"
            @test DistSSHRun.drive_parsed_from_session(
                session,
                script;
                julia = "auto",
            ).julia === nothing

            err_old_sync = try
                DistSSHRun.drive_parsed_from_session(session, script; sync = :sync)
                nothing
            catch e
                e
            end
            @test err_old_sync isa ArgumentError
            @test occursin("sync=:sync was removed", err_old_sync.msg)

            err_git_sync = try
                DistSSHRun.drive_parsed_from_session(session, script; sync = :git_sync)
                nothing
            catch e
                e
            end
            @test err_git_sync isa ArgumentError
            @test occursin("no longer transfers", err_git_sync.msg)

            err_ship_sync = try
                DistSSHRun.drive_parsed_from_session(
                    session,
                    script;
                    sync = :ship_tree,
                    skip_hash_check = false,
                )
                nothing
            catch e
                e
            end
            @test err_ship_sync isa ArgumentError
            @test occursin("sync=:ship_tree was removed", err_ship_sync.msg)

            err_drive_ss = try
                DistSSHRun.drive!(script, ["parent:1"]; sync_script = true, yes = true)
                nothing
            catch e
                e
            end
            @test err_drive_ss isa ArgumentError
            @test occursin("sync_script= was removed", err_drive_ss.msg)
        end
    end

    @testset "sync! refusals" begin
        _with_tempdir() do tmp
            local_only = DistSSHRun.DistSSHSession(
                project = tmp, workers = ["parent:2"], quiet = true,
            )
            remote = DistSSHRun.DistSSHSession(project = tmp, workers = ["child:h1"], quiet = true)
            with_kit_verbosity(:progress) do
                @test_throws ArgumentError DistSSHRun.sync!(local_only)
                @test_throws ArgumentError DistSSHRun.sync!(local_only; mode = false)
                @test_throws ArgumentError DistSSHRun.sync!(remote; mode = nothing)
                @test_throws ArgumentError DistSSHRun.sync!(remote; mode = :nope)
            end
        end
    end

    @testset "drive runtime helpers" begin
        # `checks.jl` / `workers.jl` live in DistSSHRun (not Main fragments).
        _with_tempdir() do tmp
            with_kit_verbosity(:progress) do
                DistSSHRun.apply_shared_cli_flags!(
                    DistSSHRun.CliSharedFlags(quiet = true, yes = true),
                )
                redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        ok, mm, uv = DistSSHRun.check_git_hashes(String[], tmp)
                        @test ok
                        @test isempty(mm)
                        @test isempty(uv)
                        @test !DistSSHRun._skip_global_worker_pkill()
                        withenv("DISTSSH_SKIP_GLOBAL_WORKER_PKILL" => "1") do
                            @test DistSSHRun._skip_global_worker_pkill()
                            DistSSHRun.cleanup_stale_workers!(Tuple{String, Union{Int, Nothing}}[])
                        end
                    end
                end
            end
            missing = joinpath(tmp, "no_such_driver.jl")
            msg = DistSSHRun.drive_script_not_found_message(missing, tmp; surface = :api)
            @test occursin("not found", lowercase(msg))
        end
    end

    @testset "instantiate! requires SSH hosts" begin
        _with_tempdir() do tmp
            session = DistSSHRun.DistSSHSession(
                project = tmp, workers = ["parent:2"], quiet = true,
            )
            with_kit_verbosity(:progress) do
                @test_throws ArgumentError DistSSHRun.instantiate!(session)
            end
        end
    end

    @testset "collect! requires hosts" begin
        _with_tempdir() do tmp
            session = DistSSHRun.DistSSHSession(
                project = tmp, workers = ["parent:2"], quiet = true,
            )
            err = try
                with_kit_verbosity(:progress) do
                    DistSSHRun.collect!(session, joinpath(tmp, "out"))
                end
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("collect!", sprint(showerror, err))
        end
    end

    @testset "collect! scopes session.remote into ENV" begin
        _with_tempdir() do state_dir
            _with_tempdir() do tmp
                write(joinpath(tmp, "Project.toml"), "name = \"DriveRemoteEnv\"\n")
                ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = "/caller/Keep"
                session = DistSSHRun.DistSSHSession(
                    project = tmp,
                    workers = ["child:host1"],
                    remote = "/session/Custom",
                    quiet = true,
                    yes = true,
                )
                seen = Ref{Union{Nothing, String}}(nothing)
                fake = merge(
                    _fake_setup_remote_env(state_dir),
                    Dict("DISTSSH_TEST_SNAP_GIT_YES" => "1"),
                )
                withenv(fake...) do
                    DistSSHRun._with_session_remote_env!(session) do
                        seen[] = get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", nothing)
                        @test DistSSHRun.remote_deploy_root(tmp) == "/session/Custom"
                        @test DistSSHRun._remote_work_layout_path(
                            tmp, tmp, ["host1"],
                        ) == "/session/Custom"
                    end
                end
                @test seen[] == DistSSHRun.remote_env_project_root("/session/Custom")
                @test ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] == "/caller/Keep"
                delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
                err = try
                    DistSSHRun._with_session_remote_env!(session) do
                        @test ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] ==
                            DistSSHRun.remote_env_project_root("/session/Custom")
                        error("force-fail")
                    end
                catch e
                    e
                end
                @test err isa ErrorException
                @test !haskey(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
            end
        end
    end

    @testset "report_pipeline_errors" begin
        ok = DistSSHRun.PipelineResult(
            true, nothing, nothing, nothing, nothing, "job.jl",
        )
        @test DistSSHRun.report_pipeline_errors(ok)
        @test DistSSHRun.kit_run_result(ok).exit_code == 0
        dr = DistSSHRun.DriveResult(false, 7; output_dir = "/out", failed_step = "drive")
        @test dr.output_dir == "/out"
        @test isempty(dr.hosts)
        @test DistSSHRun.kit_run_result(dr).kind === :drive
        @test DistSSHRun.kit_run_result(dr).exit_code == 7
        @test DistSSHRun.result_run_dir(dr) === nothing
        @test DistSSHRun.result_provenance(dr) === nothing
        mktempdir() do run_dir
            DistSSHRun.write_kit_run_toml!(
                run_dir;
                kind = :drive,
                result = DistSSHRun.DistSSHJobResult(false, :drive, "/out", nothing, "drive", 7),
            )
            held = DistSSHRun.DriveResult(
                false, 7;
                output_dir = "/out",
                failed_step = "drive",
                run_dir = run_dir,
            )
            prov = DistSSHRun.result_provenance(held)
            @test prov isa AbstractDict
            @test prov["kind"] == "drive"
            @test DistSSHRun.result_run_dir(held) == run_dir
            @test DistSSHRun.kit_run_result(held).run_dir == run_dir
            @test DistSSHRun.result_run_dir(DistSSHRun.kit_run_result(held)) == run_dir
            go = DistSSHRun.GoResult(
                false, nothing, held, nothing, "job.jl", "/out";
                failed_step = "run",
                run_dir = run_dir,
            )
            go_prov = DistSSHRun.result_provenance(go)
            @test go_prov isa AbstractDict
            @test go_prov["kind"] == "drive"
        end

        hosts = [
            DistSSHRun.HostRunResult("h1", true),
            DistSSHRun.HostRunResult("h2", false, ErrorException("boom")),
        ]
        dr_hosts = DistSSHRun.DriveResult(false, 1; failed_step = "drive", hosts = hosts)
        @test length(dr_hosts.hosts) == 2
        @test dr_hosts.hosts[1] == DistSSHRun.HostRunResult("h1", true, nothing)
        @test dr_hosts.hosts[2].host == "h2"
        @test !dr_hosts.hosts[2].ok
        @test dr_hosts.hosts[2].error == "boom"
        @test DistSSHRun.kit_run_result(dr_hosts).hosts == dr_hosts.hosts
        bad = DistSSHRun.PipelineResult(
            false,
            DistSSHRun.SyncResult(false, [DistSSHRun.HostResult("h1", false, "rsync refuse")], false),
            nothing,
            DistSSHRun.DriveResult(false, 1),
            DistSSHRun.CollectResult(false, 1),
            "job.jl";
            failed_step = "drive",
        )
        buf = IOBuffer()
        @test !DistSSHRun.report_pipeline_errors(bad; io = buf)
        txt = String(take!(buf))
        @test occursin("pipeline! failed at step: drive", txt)
        @test occursin("sync h1: rsync refuse", txt)
        @test occursin("drive exit 1", txt)
        @test occursin("collect exit 1", txt)
        kr = DistSSHRun.kit_run_result(bad)
        @test kr.kind === :pipeline
        @test kr.exit_code == 1
        @test kr.failed_step == "drive"
        @test !DistSSHRun.report_run_errors(bad; io = IOBuffer())
    end

    @testset "pipeline! missing driver surfaces" begin
        _with_tempdir() do tmp
            missing = joinpath(tmp, "demos", "with_kit", "rho_sweep.jl")
            cfg = DistSSHRun.PipelineConfig(project = tmp, driver = missing, workers = String[])
            err = try
                DistSSHRun.pipeline!(cfg)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("driver not found", sprint(showerror, err))
            @test occursin("DistSSHRun.install_demos(; family=", sprint(showerror, err))
        end
    end

    @testset "pipeline_config_from_env" begin
        withenv(
            "DISTSSH_HOSTS" => "child:host-a:1, child:host-b:1",
            "DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/remote/App",
            "DRIVER" => "demos/job.jl",
            "SYNC_MODE" => "off",
            "GB_PER_WORKER" => "2.0",
            "DISTSSH_HOSTS_FILE" => "",
            "JULIA_DISTRIBUTED_EXE" => "/opt/julia/bin/julia",
        ) do
            err = try
                DistSSHRun.pipeline_config_from_env()
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("GB_PER_WORKER", sprint(showerror, err))
        end
        withenv(
            "DISTSSH_HOSTS" => "child:host-a:1, child:host-b:1",
            "DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/remote/App",
            "DRIVER" => "demos/job.jl",
            "SYNC_MODE" => "off",
            "DISTSSH_HOSTS_FILE" => "",
            "JULIA_DISTRIBUTED_EXE" => "/opt/julia/bin/julia",
        ) do
            cfg = DistSSHRun.pipeline_config_from_env()
            @test cfg.tokens == ["child:host-a:1", "child:host-b:1"]
            @test cfg.remote == "/remote/App"
            @test cfg.driver == "demos/job.jl"
            @test cfg.julia == "/opt/julia/bin/julia"
        end
        withenv(
            "DRIVER" => "demos/job.jl",
            "DISTSSH_HOSTS" => "",
            "DISTSSH_HOSTS_FILE" => "",
            "JULIA_DISTRIBUTED_EXE" => "auto",
        ) do
            @test DistSSHRun.pipeline_config_from_env().julia === nothing
        end
        let hosts_file = _sample_hosts_file()
            withenv(
                "DRIVER" => "demos/job.jl",
                "DISTSSH_HOSTS" => "child:env-a:2",
                "DISTSSH_HOSTS_FILE" => hosts_file,
                "SYNC_MODE" => "off",
                "JULIA_DISTRIBUTED_EXE" => "",
            ) do
                cfg = DistSSHRun.pipeline_config_from_env()
                @test cfg.tokens == ["child:env-a:2", "child:host-a:1", "child:host-b:4"]
                @test cfg.hosts_file === nothing
            end
        end
        let hosts_file = _sample_hosts_file()
            withenv("DISTSSH_HOSTS_FILE" => hosts_file) do
                s = DistSSHRun.DistSSHSession(workers = ["parent:1"])
                @test s.tokens == ["parent:1"]
                empty = DistSSHRun.DistSSHSession(workers = String[])
                @test empty.tokens == ["child:host-a:1", "child:host-b:4"]
            end
        end
    end

    @testset "publish source" begin
        _with_tempdir() do tmp
            p = joinpath(tmp, "plain.jl")
            write(
                p, """
                function work(x)
                    return x * x
                end
                work(x) = x
                xs = 1:8
                ys = map(work, xs)
                println(join(ys, ","))
                """
            )
            src = DistSSHRun._drive_publish_source(p)
            @test occursin("function work", src)
            @test !occursin("println", src)
            @test !occursin("1:8", src)

            lib = joinpath(tmp, "lib.jl")
            write(lib, "f() = 1\n")
            d = joinpath(tmp, "driver.jl")
            write(
                d, """
                using Distributed
                include("lib.jl")
                function main()
                    pmap(identity, 1:2)
                end
                println("no")
                """
            )
            dsrc = DistSSHRun._drive_publish_source(d)
            @test occursin("using Distributed", dsrc)
            @test occursin("include", dsrc)
            @test occursin("function main", dsrc)
            @test occursin("pmap", dsrc)
            @test !occursin("println", dsrc)

            g = joinpath(tmp, "guarded.jl")
            write(
                g, """
                using Distributed
                const DEMO_JL = joinpath(@__DIR__, "lib.jl")
                isdefined(Main, :load_full_config) || include(DEMO_JL)
                if !isdefined(Main, :other)
                    include("other.jl")
                end
                function main()
                    pmap(identity, 1:2)
                end
                """
            )
            gsrc, gwarns = DistSSHRun._drive_publish_extract(g)
            @test occursin("using Distributed", gsrc)
            @test occursin("function main", gsrc)
            @test !occursin("include(DEMO_JL)", gsrc)
            @test !occursin("include(\"other.jl\")", gsrc)
            @test length(gwarns) == 2
            @test occursin("line 3:", gwarns[1])
            @test occursin("inside if/||/&&", gwarns[1])
            @test occursin("--worker-include", gwarns[1])
            @test occursin("line 4:", gwarns[2]) || occursin("line 5:", gwarns[2])
            gout, _ = _capture_stdio() do _, _
                DistSSHRun._drive_publish_source(g)
            end
            @test occursin("is not published", gout)
            @test occursin("--worker-include", gout)
        end
    end

    @testset "drive process frame (#185)" begin
        keys = (
            "DISTRIBUTED_PROJECT_ROOT",
            "DISTRIBUTED_REMOTE_PROJECT_ROOT",
            "DISTRIBUTED_OUTPUT_DIR",
            "DISTRIBUTED_RUNNER",
        )
        snap() = Dict(k => get(ENV, k, nothing) for k in keys)
        _mktemp_host() do proj
            _write_host_project!(proj, "DriveFrame")
            projfile = joinpath(proj, "Project.toml")
            saved_raw = Base.ACTIVE_PROJECT[]
            try
                withenv(
                    "DISTRIBUTED_PROJECT_ROOT" => nothing,
                    "DISTRIBUTED_REMOTE_PROJECT_ROOT" => "",
                    "DISTRIBUTED_OUTPUT_DIR" => "keep-me",
                    "DISTRIBUTED_RUNNER" => nothing,
                ) do
                    pinned = snap()
                    Base.ACTIVE_PROJECT[] = nothing
                    err = try
                        DistSSHRun._with_drive_process!(proj) do
                            @test Base.ACTIVE_PROJECT[] == projfile
                            ENV["DISTRIBUTED_PROJECT_ROOT"] = proj
                            ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = "/remote"
                            ENV["DISTRIBUTED_OUTPUT_DIR"] = joinpath(proj, "out")
                            ENV["DISTRIBUTED_RUNNER"] = "1"
                            error("drive-frame-boom")
                        end
                        nothing
                    catch e
                        e
                    end
                    @test err isa ErrorException
                    @test occursin("drive-frame-boom", err.msg)
                    @test Base.ACTIVE_PROJECT[] === nothing
                    @test snap() == pinned
                    interrupted = try
                        DistSSHRun._with_drive_process!(proj) do
                            ENV["DISTRIBUTED_RUNNER"] = "1"
                            throw(DistSSHRun._DriveProcessInterrupt())
                        end
                        nothing
                    catch e
                        e
                    end
                    @test interrupted isa DistSSHRun._DriveProcessInterrupt
                    @test Base.ACTIVE_PROJECT[] === nothing
                    @test snap() == pinned
                    @test get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", "missing") == ""
                    @test !haskey(ENV, "DISTRIBUTED_PROJECT_ROOT")
                    @test !haskey(ENV, "DISTRIBUTED_RUNNER")
                end
            finally
                Base.ACTIVE_PROJECT[] = saved_raw
            end
        end
    end

    @testset "cli interrupt flag does not stick" begin
        DistSSHRun._clear_interrupted!()
        try
            left = try
                DistSSHRun._drive_frame(; cli = true) do
                    DistSSHRun._mark_interrupted!()
                    error("cli-interrupt")
                end
                nothing
            catch e
                e
            end
            @test left isa DistSSHRun._DriveProcessInterrupt
            @test DistSSHRun._drive_was_interrupted()
            seen = Ref(true)
            ordinary = try
                DistSSHRun._drive_frame() do
                    seen[] = DistSSHRun._drive_was_interrupted()
                    error("ordinary")
                end
                nothing
            catch e
                e
            end
            @test seen[] == false
            @test ordinary isa ErrorException
            @test occursin("ordinary", ordinary.msg)
            @test !DistSSHRun._drive_was_interrupted()
        finally
            DistSSHRun._clear_interrupted!()
        end
    end

    @testset "SIGINT disposition is restored on 1.13" begin
        if isdefined(Base, :CANCEL_TOKEN)
            @test_skip "SIGINT sa handler restoration needs builds without Base.CANCEL_TOKEN (1.13, 1.14.0-beta1+)"
        else
            before = _sigint_sa_handler()
            DistSSHRun._drive_frame() do
                DistSSHRun._drive_cancellable() do
                    return nothing
                end
            end
            @test _sigint_sa_handler() == before
            DistSSHRun._arm_second_sigint!()
            DistSSHRun._disarm_second_sigint!()
            @test _sigint_sa_handler() == before
        end
    end

    @testset "init delay" begin
        @test DistSSHRun._drive_init_delay_sec(; ssh = false) == 0.0
        withenv("DISTRIBUTED_INIT_DELAY_SEC" => nothing) do
            @test DistSSHRun._drive_init_delay_sec(; ssh = true) == 5.0
        end
        withenv("DISTRIBUTED_INIT_DELAY_SEC" => "0") do
            @test DistSSHRun._drive_init_delay_sec(; ssh = true) == 0.0
        end
    end

    # `-orphan` is rejected before `ssh` runs, so these drives do not connect.
    # A newline in the remote root throws inside `add_drive_workers!` after
    # the planned list is written, and before a remote command is built.
    @testset "kit.hosts around join (#213)" begin
        hosts_of(names) = Tuple{String, Union{Int, Nothing}}[(String(n), 1) for n in names]
        planned = hosts_of(["h1", "h2", "h1"])

        _with_tempdir() do tmp
            out = joinpath(tmp, "out")
            log = joinpath(tmp, "log")
            mkpath(out)
            mkpath(log)
            script = joinpath(tmp, "job.jl")
            write(script, "")
            msg = try
                redirect_stdout(devnull) do
                    DistSSHRun.add_drive_workers!(
                        Tuple{String, Union{Int, Nothing}}[],
                        0, nothing, nothing, tmp, script, tmp,
                    )
                end
                ""
            catch e
                e isa ErrorException ? e.msg : sprint(showerror, e)
            end
            @test msg == DistSSHRun._NO_WORKERS_JOINED

            seen = Ref(String[])
            seen_log = Ref(String[])
            joined = DistSSHRun._drive_kit_hosts_around_join!(planned, out, log) do
                seen[] = DistSSHRun._read_kit_hosts(out)
                seen_log[] = DistSSHRun._read_kit_hosts(log)
                return String["h2"]
            end
            @test seen[] == ["h1", "h2"]
            @test seen_log[] == ["h1", "h2"]
            @test joined == ["h2"]
            @test DistSSHRun._read_kit_hosts(out) == ["h2"]
            @test DistSSHRun._read_kit_hosts(log) == ["h2"]

            write(joinpath(out, "kit.hosts"), "stale\n")
            write(joinpath(log, "kit.hosts"), "stale\n")
            none = DistSSHRun._drive_kit_hosts_around_join!(
                Tuple{String, Union{Int, Nothing}}[], out, log,
            ) do
                return String[]
            end
            @test isempty(none)
            @test !isfile(joinpath(out, "kit.hosts"))
            @test !isfile(joinpath(log, "kit.hosts"))

            DistSSHRun._clear_interrupted!()
            try
                empty_err = try
                    DistSSHRun._drive_frame() do
                        DistSSHRun._drive_kit_hosts_around_join!(planned, out, nothing) do
                            seen[] = DistSSHRun._read_kit_hosts(out)
                            error(DistSSHRun._NO_WORKERS_JOINED)
                        end
                    end
                    nothing
                catch e
                    e
                end
                @test seen[] == ["h1", "h2"]
                @test empty_err isa ErrorException
                @test empty_err.msg == DistSSHRun._NO_WORKERS_JOINED
                @test !isfile(joinpath(out, "kit.hosts"))
                @test !DistSSHRun._drive_was_interrupted()

                other = try
                    DistSSHRun._drive_frame() do
                        DistSSHRun._drive_kit_hosts_around_join!(planned, out, nothing) do
                            error("ssh exploded")
                        end
                    end
                    nothing
                catch e
                    e
                end
                @test other isa ErrorException
                @test occursin("ssh exploded", other.msg)
                @test DistSSHRun._read_kit_hosts(out) == ["h1", "h2"]

                interrupted = try
                    DistSSHRun._drive_frame() do
                        DistSSHRun._drive_kit_hosts_around_join!(planned, out, nothing) do
                            throw(InterruptException())
                        end
                    end
                    nothing
                catch e
                    e
                end
                @test interrupted isa InterruptException
                @test DistSSHRun._read_kit_hosts(out) == ["h1", "h2"]
                @test !DistSSHRun._drive_was_interrupted()

                later = try
                    DistSSHRun._drive_frame() do
                        DistSSHRun._drive_kit_hosts_around_join!(planned, out, nothing) do
                            return String["h1"]
                        end
                        DistSSHRun._drive_cancellable() do
                            throw(InterruptException())
                        end
                    end
                    nothing
                catch e
                    e
                end
                @test later isa InterruptException
                @test DistSSHRun._read_kit_hosts(out) == ["h1"]

                blown = try
                    DistSSHRun._drive_frame() do
                        DistSSHRun._drive_kit_hosts_around_join!(planned, out, nothing) do
                            return String["h2"]
                        end
                        error("script failed")
                    end
                    nothing
                catch e
                    e
                end
                @test blown isa ErrorException
                @test occursin("script failed", blown.msg)
                @test DistSSHRun._read_kit_hosts(out) == ["h2"]
            finally
                DistSSHRun._clear_interrupted!()
                DistSSHRun._disarm_second_sigint!()
            end
        end

        function _hosts_on_disk(root::String)::Vector{String}
            found = String[]
            isdir(root) || return found
            for (dir, _, files) in walkdir(root)
                if "kit.hosts" in files
                    push!(found, joinpath(dir, "kit.hosts"))
                end
            end
            return found
        end

        function _drive_bad_host(proj::String)
            # Do not define `main`. `integration/drive/api.jl` is the first
            # in-process driver include and rejects a later overwrite warning.
            script = joinpath(proj, "job.jl")
            write(script, "# driver include only\n")
            out = joinpath(proj, "batch-out")
            mkpath(out)
            session = DistSSHRun.DistSSHSession(
                project = proj,
                workers = String[],
                quiet = true,
                yes = true,
                verbosity = :quiet,
            )
            parsed = DistSSHRun.drive_parsed_from_session(
                session,
                script;
                workers = DistSSHRun.WorkerPlan(0, Dict("-orphan" => 1)),
                enable_log = false,
                skip_hash_check = true,
                output_dir = out,
                julia = joinpath(Sys.BINDIR, Base.julia_exename()),
                require_all_hosts = false,
            )
            err = redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    try
                        DistSSHRun.run_drive_parsed!(parsed; project_root = proj)
                        nothing
                    catch e
                        e
                    end
                end
            end
            return (err = err, out = out)
        end

        _with_tempdir() do state_dir
            ssh_base = (
                _fake_setup_remote_env(state_dir)...,
                "DISTRIBUTED_SSH_OPTS" => "-o BatchMode=yes -o ConnectTimeout=1",
                "DISTSSH_JOB_ID" => nothing,
                "DISTSSH_SKIP_GLOBAL_WORKER_PKILL" => "1",
                "DISTSSH_TEST_SNAP_GIT_YES" => "1",
            )
            _mktemp_host() do proj
                _write_host_project!(proj, "HostsKeep")
                got = withenv(
                    ssh_base...,
                    "DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/tmp/distsshkit-remote\nbad",
                ) do
                    _drive_bad_host(proj)
                end
                @test got.err isa ArgumentError
                @test occursin("newline", sprint(showerror, got.err))
                # Failure is before the workers step, so kit.hosts is not written yet.
                @test isempty(DistSSHRun._read_kit_hosts(got.out))
                @test isempty(vcat(_hosts_on_disk(proj), _hosts_on_disk(got.out)))
            end

            _mktemp_host() do proj
                _write_host_project!(proj, "HostsDrop")
                got = withenv(
                    ssh_base...,
                    "DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/tmp/distsshkit-remote",
                ) do
                    _drive_bad_host(proj)
                end
                @test got.err isa ErrorException
                @test got.err.msg == DistSSHRun._NO_WORKERS_JOINED
                @test !isfile(joinpath(got.out, "kit.hosts"))
                @test isempty(_hosts_on_disk(proj))
                @test isempty(_hosts_on_disk(got.out))
            end
        end
    end

    @testset "snapshot does not reject a sibling path source" begin
        _with_tempdir() do root
            app = joinpath(root, "app")
            bar = joinpath(root, "Bar")
            mkpath(joinpath(app, "src"))
            mkpath(joinpath(bar, "src"))
            write(joinpath(app, "src", "App.jl"), "module App\nend\n")
            write(joinpath(bar, "src", "Bar.jl"), "module Bar\nend\n")
            write(
                joinpath(bar, "Project.toml"),
                """
                name = "Bar"
                uuid = "22222222-2222-4222-8222-222222222222"
                version = "0.1.0"
                """,
            )
            write(
                joinpath(app, "Project.toml"),
                """
                name = "App"
                uuid = "11111111-1111-4111-8111-111111111111"
                version = "0.1.0"
                """,
            )
            cmd = setenv(
                `$(_julia_exe()) --project=$app --startup-file=no -e "using Pkg; Pkg.develop(path=$(repr(bar)))"`,
                _child_julia_env(),
            )
            proc, combined = _run_subprocess(cmd)
            _assert_proc_ok(proc, combined; label = "Pkg.develop Bar")
            for name in ("Project.toml", "Manifest.toml")
                path = joinpath(app, name)
                write(path, replace(read(path, String), "path = \"$bar\"" => "path = \"../Bar\""))
            end
            @test occursin("path = \"../Bar\"", read(joinpath(app, "Project.toml"), String))
            script = joinpath(app, "job.jl")
            marker = joinpath(root, "RAN")
            write(script, "write($(repr(marker)), \"yes\")\n")
            result = redirect_stdout(devnull) do
                mktemp() do err_path, err_io
                    inner = redirect_stderr(err_io) do
                        DistSSHRun.drive!(
                            script, ["parent:1"];
                            project = app,
                            run_id = "20260101T000000Z-aaaaaa",
                            yes = true,
                            quiet = true,
                            enable_log = false,
                        )
                    end
                    flush(err_io)
                    err = read(err_path, String)
                    @test !occursin("heartbeat", lowercase(err))
                    @test !isdefined(Main, :stop_heartbeat_monitor)
                    @test !isdefined(Main, :start_heartbeat_monitor)
                    return inner
                end
            end
            @test result.ok
            @test result.exit_code == 0
            @test isfile(marker)
        end
    end

    @testset "run_id keyword on drive collect and outside-script guard" begin
        root = mktempdir()
        try
            proj = joinpath(root, "proj")
            mkpath(proj)
            write(joinpath(proj, "Project.toml"), "name = \"DrvKw\"\nversion = \"0.1.0\"\n")
            outside = joinpath(root, "outside.jl")
            write(outside, "1\n")
            @test DistSSHRun._reject_script_outside_project_run!(
                "drive", proj, outside;
                run_id = "20260101T000000Z-aaaaaa",
                remote_argv = false,
            ) === nothing
        finally
            rm(root; force = true, recursive = true)
        end
        collect_m = methods(DistSSHRun.drive_collect_tree)[1]
        kws = Base.kwarg_decl(collect_m)
        @test :run_id in kws
        @test :snapshot ∉ kws
        rej_m = methods(DistSSHRun._reject_script_outside_project_run!)[1]
        rej_kws = Base.kwarg_decl(rej_m)
        @test :run_id in rej_kws
        @test :snapshot ∉ rej_kws
    end
end
