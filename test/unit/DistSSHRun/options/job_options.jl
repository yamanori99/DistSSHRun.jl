using DistSSHRun
using Test

@testset "CollectJobOptions" begin
    opts = DistSSHRun.collect_job_options(merge = true, best_effort = true, remote_root = "/remote")
    @test opts.merge
    @test opts.best_effort
    @test opts.remote_root == "/remote"
end

@testset "drive_job_options_from_parsed" begin
    parsed = (
        head_workers = 1,
        default_workers = nothing,
        julia = nothing,
        skip_hash_check = false,
        enable_log = true,
        log_dir = nothing,
        output_dir = nothing,
        explicit_package = nothing,
        hosts = Tuple{String, Union{Int, Nothing}}[("host1", 2)],
        script_path = "job.jl",
        script_args = String["1"],
        collect_root = nothing,
        collect_hosts = nothing,
        collect_overwrite = nothing,
        worker_include = false,
        best_effort = false,
        help = false,
        show_version = false,
        cli_session = DistSSHRun.default_kit_cli_session(),
        hint_surface = :cli,
        unsafe_skip_env_digests = false,
        unsafe_expose_port = false,
        unsafe_all_to_all = false,
        print_config = false,
        dry_run = false,
        ship_id = nothing,
        deploy_root = nothing,
        isolated = false,
        unsafe_master_silence_exit = missing,
    )
    dopts = DistSSHRun.drive_job_options_from_parsed(parsed)
    @test !dopts.skip_hash_check
    @test !dopts.best_effort
    @test dopts.config.command === :drive
end
