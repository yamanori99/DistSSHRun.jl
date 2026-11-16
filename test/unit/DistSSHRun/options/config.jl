using Test, DistSSHRun

@testset "run option table and config" begin
    @testset "registry anchors" begin
        anchors = String[]
        codes = String[]
        for (kind, spec) in DistSSHRun.ERROR_REGISTRY
            push!(anchors, spec.anchor)
            push!(codes, spec.code)
        end
        @test length(unique(codes)) == length(codes)
        @test length(unique(anchors)) == length(anchors)
        @test all(c -> startswith(c, "DSSH-E"), codes)
    end

    @testset "help matches table for go" begin
        gen = DistSSHRun.generated_run_option_help(:go)
        buf = IOBuffer()
        DistSSHRun.show_go_usage(; io = buf)
        txt = String(take!(buf))
        for line in gen
            @test occursin(line, txt)
        end
    end

    @testset "precedence env over default" begin
        let old = get(ENV, "DISTSSH_UNSAFE_SKIP_ENV_DIGESTS", nothing)
            try
                ENV["DISTSSH_UNSAFE_SKIP_ENV_DIGESTS"] = "1"
                cfg = DistSSHRun.resolve_run_job_config(; command = :go)
                @test cfg.unsafe_skip_env_digests.value == true
                @test cfg.unsafe_skip_env_digests.source == DistSSHRun.FromEnv
            finally
                old === nothing ? delete!(ENV, "DISTSSH_UNSAFE_SKIP_ENV_DIGESTS") :
                    (ENV["DISTSSH_UNSAFE_SKIP_ENV_DIGESTS"] = old)
            end
        end
    end

    @testset "cli overrides env" begin
        let old = get(ENV, "DISTSSH_UNSAFE_SKIP_ENV_DIGESTS", nothing)
            try
                ENV["DISTSSH_UNSAFE_SKIP_ENV_DIGESTS"] = "1"
                cfg = DistSSHRun.resolve_run_job_config(;
                    command = :go,
                    cli_unsafe_skip_env_digests = false
                )
                @test cfg.unsafe_skip_env_digests.value == false
                @test cfg.unsafe_skip_env_digests.source == DistSSHRun.FromCLI
            finally
                old === nothing ? delete!(ENV, "DISTSSH_UNSAFE_SKIP_ENV_DIGESTS") :
                    (ENV["DISTSSH_UNSAFE_SKIP_ENV_DIGESTS"] = old)
            end
        end
    end

    @testset "legacy flag usage error" begin
        @test_throws ArgumentError parse_go_args(["--unsafe-heterogeneous", "script.jl"])
        let err = try
                parse_go_args(["--unsafe-heterogeneous", "script.jl"])
            catch e
                e
            end
            msg = err isa ArgumentError ? err.msg : sprint(showerror, err)
            @test occursin("DSSH-E001", msg)
            @test occursin("--unsafe-skip-env-digests", msg)
        end
    end

    @testset "dry-run per-host launch" begin
        let cfg = DistSSHRun.resolve_run_job_config(;
                command = :go,
                cli_dry_run = true,
                cli_unsafe_expose_port = true,
            ),
                buf = IOBuffer()
            DistSSHRun.print_run_job_dry_plan!(
                buf,
                cfg;
                hosts = ["lab-a", "lab-b"],
                worker_tokens = String[],
                project = pwd(),
                head_slots = 0,
                bind_overrides = Dict("lab-b" => "10.0.0.2"),
            )
            txt = String(take!(buf))
            @test occursin("launch (per host):", txt)
            @test occursin("lab-a:", txt)
            @test occursin("bind=127.0.0.1", txt)
            @test occursin("lab-b:", txt)
            @test occursin("bind=10.0.0.2", txt)
            @test !occursin("phase 4", txt)
        end
        let cfg = DistSSHRun.resolve_run_job_config(;
                command = :go,
                cli_dry_run = true,
            )
            @test_throws ArgumentError DistSSHRun.print_run_job_dry_plan!(
                IOBuffer(),
                cfg;
                hosts = ["lab"],
                worker_tokens = String[],
                project = pwd(),
                head_slots = 0,
                bind_overrides = Dict("lab" => "10.0.0.2"),
            )
        end
    end

    @testset "dry-run hosts_source" begin
        let cfg = DistSSHRun.resolve_run_job_config(;
                command = :go,
                cli_dry_run = true
            ),
                buf = IOBuffer()
            DistSSHRun.print_run_job_dry_plan!(
                buf,
                cfg;
                hosts = ["cli-h"],
                worker_tokens = String[],
                project = pwd(),
                head_slots = 0,
                hosts_source = :hosts
            )
            txt = String(take!(buf))
            @test occursin("hosts_source = \"--hosts\"", txt)
        end
        let cfg = DistSSHRun.resolve_run_job_config(;
                command = :go,
                cli_dry_run = true
            ),
                buf = IOBuffer()
            DistSSHRun.print_run_job_dry_plan!(
                buf,
                cfg;
                hosts = String[],
                worker_tokens = String[],
                project = pwd(),
                head_slots = 1,
                go_implicit_no_hosts = true
            )
            txt = String(take!(buf))
            @test occursin("1 slot (no hosts given)", txt)
        end
    end

    @testset "showerror golden DSSH-E001" begin
        err = DistSSHRun.removed_cli_flag_error(;
            flag = "--unsafe-heterogeneous",
            replacement = "--unsafe-skip-env-digests",
            surface = "go"
        )
        shown = sprint(showerror, err)
        @test occursin("DSSH-E001", shown)
        @test occursin("Fix:", shown)
    end
end
