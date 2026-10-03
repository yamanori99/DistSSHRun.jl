using Test

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

        _with_tempdir() do tmp
            session = DistSSHRun.KitSession(
                project = tmp,
                workers = ["parent"],
                include_parent_for_size = true,
            )
            @test_throws ArgumentError DistSSHRun.worker_plan_from_tokens(["parent"])
            plan = DistSSHRun.size!(session; gb_per_worker = 2.0)
            local_total, local_nproc = DistSSHRun.get_local_resources()
            @test plan.parent_workers == DistSSHRun.size_worker_count(
                local_total, local_nproc, 2.0; is_parent = true,
            )
            @test isempty(plan.child_workers)
        end
    end

    @testset "KitSession" begin
        _with_tempdir() do tmp
            withenv("DISTSSHKIT_HOSTS_FILE" => "") do
                session = DistSSHRun.KitSession(project = tmp, workers = ["child:host-a", "child:host-b:4"])
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
            session = DistSSHRun.KitSession(
                project = tmp,
                workers = ["child:host-a"],
                remote = "/remote/App.jl",
                quiet = true,
                yes = true,
            )
            DistSSHRun.apply_session_env!(session)
            @test ENV["DISTRIBUTED_PROJECT_ROOT"] == abspath(tmp)
            @test ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] == "/remote/App.jl"
            @test DistSSHRun.kit_output_quiet()
            @test DistSSHRun.kit_noninteractive()
        end
        _with_tempdir() do tmp
            tilde = DistSSHRun.KitSession(
                project = tmp,
                workers = ["child:host-a"],
                remote = "~/jobs/abc",
                quiet = true,
                yes = true,
            )
            DistSSHRun.apply_session_env!(tilde)
            @test ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] == "~/jobs/abc"
        end
        _with_tempdir() do tmp
            ambient = DistSSHRun.KitSession(
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
        delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
        delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
        DistSSHRun.set_kit_output_quiet!(false)
        DistSSHRun.set_kit_noninteractive!(false)
    end

    @testset "session_remote_root / session_size_hosts" begin
        _with_tempdir() do tmp
            session = DistSSHRun.KitSession(
                project = tmp,
                workers = ["child:h1:1"],
                remote = "/remote/App.jl",
                include_parent_for_size = true,
            )
            @test DistSSHRun.session_remote_root(session) == "/remote/App.jl"
            all_h, remotes = DistSSHRun.session_size_hosts(session)
            @test all_h == ["parent", "h1"]
            @test remotes == ["h1"]
            remote_only = DistSSHRun.KitSession(project = tmp, workers = ["child:h1:1"])
            a2, r2 = DistSSHRun.session_size_hosts(remote_only)
            @test a2 == ["h1"]
            @test r2 == ["h1"]
        end
    end

    @testset "pipeline helpers" begin
        cfg = DistSSHRun.PipelineConfig(
            driver = "job.jl",
            workers = ["child:host-a"],
            sync = :rsync,
        )
        session = DistSSHRun.kit_session_from_config(cfg)
        @test DistSSHRun.resolve_pipeline_sync(cfg, session) === :rsync
        @test DistSSHRun.resolve_pipeline_collect(cfg, session)

        # Git parity off by default; sync mode does not flip it.
        default_cfg = DistSSHRun.PipelineConfig(driver = "job.jl", workers = ["child:host-a"])
        default_session = DistSSHRun.kit_session_from_config(default_cfg)
        @test DistSSHRun.resolve_pipeline_sync(default_cfg, default_session) === false
        @test DistSSHRun.pipeline_skip_hash_check(default_cfg)
        @test default_cfg.yes == true
        @test DistSSHRun.kit_session_from_config(default_cfg).yes == true
        @test DistSSHRun.pipeline_skip_hash_check(
            DistSSHRun.PipelineConfig(driver = "job.jl", workers = ["child:host-a"], sync = :sync),
        )
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
            sync = false,
            collect = false,
        )
        local_session = DistSSHRun.kit_session_from_config(local_cfg)
        @test DistSSHRun.resolve_pipeline_sync(local_cfg, local_session) === false
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

        @test DistSSHRun._parse_env_sync_mode("rsync") === :rsync
        @test DistSSHRun._parse_env_sync_mode("sync") === :sync
        @test DistSSHRun._parse_env_sync_mode("off") === false
        @test DistSSHRun._parse_env_sync_mode("skip") === false
        @test DistSSHRun._parse_env_sync_mode("no") === false
        @test DistSSHRun._parse_env_sync_mode("") === nothing
        @test DistSSHRun._parse_env_sync_mode("  ") === nothing
        @test_throws ArgumentError DistSSHRun._parse_env_sync_mode("true")
        @test_throws ArgumentError DistSSHRun._parse_env_sync_mode("1")

        withenv(
            "DRIVER" => "",
            "DISTSSHKIT_HOSTS" => "",
            "DISTSSHKIT_HOSTS_FILE" => "",
        ) do
            @test_throws ArgumentError DistSSHRun.pipeline_config_from_env()
        end
        withenv(
            "DRIVER" => "job.jl",
            "DISTSSHKIT_QUIET" => "1",
            "DISTSSHKIT_VERBOSE" => "1",
            "DISTSSHKIT_PROGRESS" => nothing,
            "DISTSSHKIT_HOSTS" => "",
            "DISTSSHKIT_HOSTS_FILE" => "",
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
    end

    @testset "drive_parsed_from_session sync / parity" begin
        _with_tempdir() do tmp
            script = joinpath(tmp, "job.jl")
            write(script, "")
            session = DistSSHRun.KitSession(project = tmp, workers = ["child:host-a"])

            parsed = DistSSHRun.drive_parsed_from_session(session, script)
            @test parsed.sync_mode === nothing
            @test parsed.sync_script == false
            @test DistSSHRun.drive_parsed_from_session(
                session, script; sync_script = true,
            ).sync_script == true
            @test parsed.skip_hash_check == true
            @test parsed.hint_surface === :api
            @test parsed.julia === nothing
            @test parsed.mem_headroom == DistSSHRun.DEFAULT_MEM_HEADROOM
            @test parsed.parent_gb == DistSSHRun.DEFAULT_PARENT_GB
            @test parsed.require_all_hosts
            @test DistSSHRun.drive_parsed_from_session(
                session, script; require_all_hosts = false,
            ).require_all_hosts == false
            @test DistSSHRun.drive_parsed_from_session(
                session, script; mem_headroom = 0.5, parent_gb = 0.2,
            ).mem_headroom == 0.5
            @test DistSSHRun.drive_parsed_from_session(
                session, script; mem_headroom = 0.5, parent_gb = 0.2,
            ).parent_gb == 0.2

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

            parsed_sync = DistSSHRun.drive_parsed_from_session(session, script; sync = :sync)
            @test parsed_sync.sync_mode === :sync
            @test parsed_sync.skip_hash_check == true

            parsed_require = DistSSHRun.drive_parsed_from_session(
                session,
                script;
                sync = :sync,
                skip_hash_check = false,
            )
            @test parsed_require.skip_hash_check == false

            # rsync has no remote .git/; parity stays off even if requested via API
            parsed_rsync = DistSSHRun.drive_parsed_from_session(
                session,
                script;
                sync = :rsync,
                skip_hash_check = false,
            )
            @test parsed_rsync.sync_mode === :rsync
            @test parsed_rsync.skip_hash_check == true
        end
    end

    @testset "sync! refusals" begin
        _with_tempdir() do tmp
            local_only = DistSSHRun.KitSession(
                project = tmp, workers = ["parent:2"], quiet = true,
            )
            remote = DistSSHRun.KitSession(project = tmp, workers = ["child:h1"], quiet = true)
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
            @test DistSSHRun.estimate_worker_memory_gb() > 0
            total, avail = DistSSHRun.estimate_available_gb()
            @test total > 0
            @test avail > 0
            with_kit_verbosity(:progress) do
                DistSSHRun.apply_kit_cli_session!(
                    DistSSHRun.KitCliSession(quiet = true, yes = true),
                )
                redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        @test DistSSHRun.check_memory_capacity(1, Tuple{String, Union{Int, Nothing}}[], nothing)
                        ok, mm, uv = DistSSHRun.check_git_hashes(String[], tmp)
                        @test ok
                        @test isempty(mm)
                        @test isempty(uv)
                        @test !DistSSHRun._skip_global_worker_pkill()
                        withenv("DISTSSHKIT_SKIP_GLOBAL_WORKER_PKILL" => "1") do
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
            session = DistSSHRun.KitSession(
                project = tmp, workers = ["parent:2"], quiet = true,
            )
            with_kit_verbosity(:progress) do
                @test_throws ArgumentError DistSSHRun.instantiate!(session)
                @test DistSSHRun.instantiate_after_rsync!(session) === nothing
            end
        end
    end

    @testset "collect! requires hosts" begin
        _with_tempdir() do tmp
            session = DistSSHRun.KitSession(
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
            "DISTSSHKIT_HOSTS" => "child:host-a:1, child:host-b:1",
            "DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/remote/App",
            "DRIVER" => "demos/job.jl",
            "SYNC_MODE" => "off",
            "GB_PER_WORKER" => "2.0",
            "DISTSSHKIT_HOSTS_FILE" => "",
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
            "DISTSSHKIT_HOSTS" => "child:host-a:1, child:host-b:1",
            "DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/remote/App",
            "DRIVER" => "demos/job.jl",
            "SYNC_MODE" => "off",
            "DISTSSHKIT_HOSTS_FILE" => "",
            "JULIA_DISTRIBUTED_EXE" => "/opt/julia/bin/julia",
        ) do
            cfg = DistSSHRun.pipeline_config_from_env()
            @test cfg.tokens == ["child:host-a:1", "child:host-b:1"]
            @test cfg.remote == "/remote/App"
            @test cfg.driver == "demos/job.jl"
            @test cfg.sync === false
            @test cfg.julia == "/opt/julia/bin/julia"
        end
        withenv(
            "DRIVER" => "demos/job.jl",
            "DISTSSHKIT_HOSTS" => "",
            "DISTSSHKIT_HOSTS_FILE" => "",
            "JULIA_DISTRIBUTED_EXE" => "auto",
        ) do
            @test DistSSHRun.pipeline_config_from_env().julia === nothing
        end
        let hosts_file = _sample_hosts_file()
            withenv(
                "DRIVER" => "demos/job.jl",
                "DISTSSHKIT_HOSTS" => "child:env-a:2",
                "DISTSSHKIT_HOSTS_FILE" => hosts_file,
                "SYNC_MODE" => "off",
                "JULIA_DISTRIBUTED_EXE" => "",
            ) do
                cfg = DistSSHRun.pipeline_config_from_env()
                @test cfg.tokens == ["child:env-a:2", "child:host-a:1", "child:host-b:4"]
                @test cfg.hosts_file === nothing
            end
        end
        let hosts_file = _sample_hosts_file()
            withenv("DISTSSHKIT_HOSTS_FILE" => hosts_file) do
                s = DistSSHRun.KitSession(workers = ["parent:1"])
                @test s.tokens == ["parent:1"]
                empty = DistSSHRun.KitSession(workers = String[])
                @test empty.tokens == ["child:host-a:1", "child:host-b:4"]
            end
        end
    end

    @testset "warn plain script" begin
        _with_tempdir() do tmp
            p = joinpath(tmp, "plain.jl")
            write(p, "ys = map(x -> x * x, 1:3)\nprintln(join(ys, \",\"))\n")
            msg = DistSSHRun._drive_plain_script_hint(p, tmp; shown = "plain.jl")
            @test msg isa String
            @test occursin("no Distributed vocabulary", msg)
            @test occursin("Load is this include", msg)
            @test occursin("Publish", msg)
            @test occursin("--sync-script", msg)
            @test occursin("ride", msg)
            @test occursin("plain.jl", msg)

            g = joinpath(tmp, "loop.jl")
            write(g, "for i in 1:2\nend\n")
            gmsg = DistSSHRun._drive_plain_script_hint(g, tmp; shown = "loop.jl")
            @test gmsg isa String
            @test occursin("go", gmsg)

            d = joinpath(tmp, "driver.jl")
            write(d, "using Distributed\npmap(identity, 1:2)\n")
            @test DistSSHRun._drive_plain_script_hint(d, tmp) === nothing
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
            @test occursin("--sync-script", gwarns[1])
            @test occursin("line 4:", gwarns[2]) || occursin("line 5:", gwarns[2])
            gout, _ = _capture_stdio() do _, _
                DistSSHRun._drive_publish_source(g)
            end
            @test occursin("is not published", gout)
            @test occursin("--sync-script", gout)
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
end
