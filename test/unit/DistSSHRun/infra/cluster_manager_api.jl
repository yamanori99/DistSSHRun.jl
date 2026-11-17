using Test

# Pins the 0.2.0 cluster-manager contract (#469). Changing these tests is breaking.

const _CLUSTER_MANAGER_EXPORTS = (
    :LaunchReport,
    :WorkerLaunchOutcome,
    :LaunchIncompleteError,
    :launch_report_planned,
    :launch_report_joined,
    :launch_report_failures,
    :launch_report_usable,
    :launch_rank,
    :SEED_SCHEME,
    :seed_mix,
    :worker_seed,
    :job_item_seed,
    :worker_pmap,
    :WorkerPlan,
)

const _CLUSTER_MANAGER_PUBLIC_UNEXPORTED = (
    :HostLaunchFailure,
    :RunJobConfig,
    :BoolConfigField,
    :StringConfigField,
    :ConfigSource,
    :resolve_run_job_config,
    :resolve_run_job_config_from_parsed,
    :run_option_table,
    :options_for_command,
    :OptionRow,
    :unsafe_skip_env_digests_active,
    :unsafe_expose_port_active,
    :unsafe_all_to_all_active,
    :unsafe_skip_env_digests_argv,
    :with_run_unsafe_options!,
    :with_unsafe_skip_env_digests,
    :with_unsafe_expose_port,
    :with_unsafe_all_to_all,
    :DriveJobOptions,
    :resolved_placement_tokens,
    :HostLaunchPlan,
)

const _TOPOLOGY_BIND_INTERNAL = (
    :resolve_launch_bind_overrides,
    :hosts_file_bind_overrides,
    :resolved_bind_address,
    :validate_host_launch_plan,
    :format_host_launch_plan_line,
    :topology_for_launch,
    :resolved_topology,
    :default_bind_address,
)

const _RUN_OPTION_TABLE_KEYS = Set{Symbol}(
    [
        :unsafe_skip_env_digests,
        :unsafe_expose_port,
        :unsafe_all_to_all,
        :unsafe_master_silence_exit,
        :print_config,
        :dry_run,
        :topology,
    ]
)

@testset "cluster manager API freeze" begin
    for sym in _CLUSTER_MANAGER_EXPORTS
        @test sym in names(DistSSHRun)
        @test Base.isexported(DistSSHRun, sym)
    end
    for sym in _CLUSTER_MANAGER_PUBLIC_UNEXPORTED
        @test sym in names(DistSSHRun)
        @test !Base.isexported(DistSSHRun, sym)
        @test Base.ispublic(DistSSHRun, sym)
    end
    @test :cluster ∉ names(DistSSHRun)

    @test fieldnames(DistSSHRun.WorkerPlan) === (:head_workers, :child_workers)
    @test fieldnames(DistSSHRun.HostLaunchFailure) ===
        (:host, :requested, :joined, :outcome, :reason)
    @test fieldnames(DistSSHRun.LaunchReport) ===
        (:planned_workers, :joined_workers, :failures)
    @test fieldnames(DistSSHRun.LaunchIncompleteError) === (:report,)
    @test fieldnames(DistSSHRun.RunJobConfig) === (
        :unsafe_skip_env_digests,
        :unsafe_expose_port,
        :unsafe_all_to_all,
        :unsafe_master_silence_exit,
        :print_config,
        :dry_run,
        :topology,
        :command,
    )
    @test fieldnames(DistSSHRun.BoolConfigField) === (:value, :source)
    @test fieldnames(DistSSHRun.StringConfigField) === (:value, :source)
    @test fieldnames(DistSSHRun.DriveJobOptions) === (
        :config,
        :skip_hash_check,
        :best_effort,
        :worker_include,
        :enable_log,
        :isolated,
        :default_workers,
        :explicit_package,
        :run_id,
        :deploy_root,
        :julia,
    )

    @test Tuple(instances(DistSSHRun.WorkerLaunchOutcome)) == (
        DistSSHRun.Joined,
        DistSSHRun.FailedToConnect,
        DistSSHRun.FailedToLoad,
    )
    @test DistSSHRun.SEED_SCHEME === 1

    @test fieldnames(DistSSHRun.OptionRow) ===
        (:key, :cli, :env, :kwarg, :default, :commands, :help, :unsafe, :valued)
    @test fieldnames(DistSSHRun.HostLaunchPlan) === (:host, :bind, :tunnel, :topology)
    @test Base.ispublic(DistSSHRun, :HostLaunchPlan)
    @test !Base.isexported(DistSSHRun, :HostLaunchPlan)
    for sym in _TOPOLOGY_BIND_INTERNAL
        sym in names(DistSSHRun) || continue
        @test !Base.ispublic(DistSSHRun, sym)
    end
    @test Set(r.key for r in DistSSHRun.run_option_table()) == _RUN_OPTION_TABLE_KEYS
    top_row = DistSSHRun.option_row_by_key(:topology)
    @test top_row !== nothing
    @test top_row.env == "DISTSSH_TOPOLOGY"
    @test top_row.cli === nothing
    @test top_row.kwarg === :topology

    rows = DistSSHRun.run_option_table()
    unsafe_shared = Set{Symbol}()
    for row in rows
        row.unsafe || continue
        row.key in (:unsafe_master_silence_exit,) && continue
        push!(unsafe_shared, row.key)
    end
    @test unsafe_shared == Set(
        [
            :unsafe_skip_env_digests,
            :unsafe_expose_port,
            :unsafe_all_to_all,
        ]
    )
    drive_rows = DistSSHRun.options_for_command(:drive)
    @test any(r -> r.key === :unsafe_master_silence_exit, drive_rows)

    row = DistSSHRun.HostLaunchFailure("lab", 2, 0, DistSSHRun.FailedToConnect, "timeout")
    rep = DistSSHRun.LaunchReport(2, 0, [row])
    @test DistSSHRun.launch_report_planned(rep) == 2
    @test DistSSHRun.launch_report_joined(rep) == 0
    @test !DistSSHRun.launch_report_usable(rep)
    fails = DistSSHRun.launch_report_failures(rep)
    @test length(fails) == 1
    @test fails[1].host == "lab"
    @test fails[1].requested == 2
    @test fails[1].joined == 0
    @test fails[1].outcome === DistSSHRun.FailedToConnect
    @test fails[1].reason == "timeout"

    DistSSHRun.reset_worker_seeds!()
    DistSSHRun.reset_launch_rank_plan!([1])
    withenv("DISTSSH_JOB_SEED" => "99") do
        DistSSHRun.job_seed()
        DistSSHRun.take_worker_rank()
        DistSSHRun.register_launch_rank!(12345, 1)
        @test DistSSHRun.launch_rank(12345) == 1
        @test DistSSHRun.launch_rank(99999) === nothing
    end

    try
        DistSSHRun.note_launch_provenance!(rep)
        prov = DistSSHRun.assemble_provenance()
        launch = prov["launch"]
        @test launch isa AbstractDict
        @test Set(keys(launch)) == Set(["planned", "joined", "failures"])
        @test launch["planned"] == 2
        @test launch["joined"] == 0
        fail_rows = launch["failures"]
        @test fail_rows isa AbstractVector
        fr = fail_rows[1]
        @test Set(keys(fr)) == Set(["host", "requested", "joined", "outcome", "reason"])
        @test fr["host"] == "lab"
        @test fr["outcome"] == "FailedToConnect"
    finally
        DistSSHRun._PROVENANCE_LAUNCH[] = nothing
    end

    DistSSHRun.reset_worker_seeds!()
    DistSSHRun.reset_launch_rank_plan!([1, 2])
    try
        withenv("DISTSSH_JOB_SEED" => "42") do
            DistSSHRun.job_seed()
            r1 = DistSSHRun.take_worker_rank()
            r2 = DistSSHRun.take_worker_rank()
            DistSSHRun.register_launch_rank!(100, r1)
            DistSSHRun.register_launch_rank!(200, r2)
        end
        prov = DistSSHRun.assemble_provenance()
        seeds = get(prov, "seeds", nothing)
        @test seeds isa AbstractDict
        @test seeds["scheme"] == DistSSHRun.SEED_SCHEME
        @test haskey(seeds, "job")
        @test seeds["job"] == "42"
        @test haskey(seeds, "job_domain")
        workers = seeds["workers"]
        @test workers isa AbstractVector
        @test length(workers) == 2
        @test Set(keys(workers[1])) == Set(["rank", "seed"])
        @test workers[1]["rank"] == 1
        @test workers[2]["rank"] == 2
        @test all(isa(w["seed"], AbstractString) for w in workers)
    finally
        DistSSHRun.reset_worker_seeds!()
    end
end
