using Test
using DistSSHRun

@testset "env contract" begin
    @testset "options.md matches generated table" begin
        path = joinpath(pkgdir(DistSSHRun), "docs", "src", "options.md")
        got = read(path, String)
        want = DistSSHRun.generated_env_options_markdown()
        @test got == want
    end

    @testset "src literals are table or INTERNAL" begin
        root = pkgdir(DistSSHRun)
        allowed = DistSSHRun.user_env_names()
        legacy_old = Set{String}(old for (old, _) in DistSSHRun.DistSSHBase.LEGACY_ENV_RENAMES)
        pat = r"\b((?:DISTSSH_|DISTRIBUTED_)[A-Z0-9_]+)"
        bad = String[]
        for (dir, _, files) in walkdir(joinpath(root, "src"))
            for f in files
                endswith(f, ".jl") || continue
                path = joinpath(dir, f)
                text = read(path, String)
                for m in eachmatch(pat, text)
                    name = String(m.captures[1])
                    name == "JULIA_DISTRIBUTED_EXE" && continue # "keep JULIA_DISTRIBUTED_EXE"
                    startswith(name, "DISTSSH_INTERNAL_") && continue
                    name in allowed && continue
                    name in legacy_old && continue
                    endswith(name, "_ENV") && name[1:(end - 4)] in allowed && continue
                    push!(bad, "$(relpath(path, root)): $name")
                end
            end
        end
        for lib in ("DistSSHBase", "DistSSHUp", "DistSSHShip", "DistSSHHeartbeat")
            src = joinpath(root, "lib", lib, "src")
            isdir(src) || continue
            for (dir, _, files) in walkdir(src)
                for f in files
                    endswith(f, ".jl") || continue
                    path = joinpath(dir, f)
                    text = read(path, String)
                    for m in eachmatch(pat, text)
                        name = String(m.captures[1])
                        name == "JULIA_DISTRIBUTED_EXE" && continue # "keep JULIA_DISTRIBUTED_EXE"
                        startswith(name, "DISTSSH_INTERNAL_") && continue
                        name in allowed && continue
                        name in legacy_old && continue
                        endswith(name, "_ENV") && name[1:(end - 4)] in allowed && continue
                        push!(bad, "$(relpath(path, root)): $name")
                    end
                end
            end
        end
        @test isempty(bad)
    end

    @testset "legacy DISTRIBUTED_ name errors" begin
        withenv("DISTRIBUTED_SSH_OPTS" => "-o Foo=bar") do
            err = try
                DistSSHRun.snapshot_process_env()
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("DISTRIBUTED_SSH_OPTS", err.msg)
            @test occursin("DISTSSH_SSH_OPTS", err.msg)
        end
        withenv("DISTRIBUTED_OUTPUT_DIR" => "/tmp/old-out") do
            @test_throws ArgumentError DistSSHRun.DistSSHBase.stored_path("a.bin")
            @test_throws ArgumentError DistSSHRun.resolve_distributed_output_dir!(
                String[],
                mktempdir(),
            )
        end
        withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/srv/staged") do
            @test_throws ArgumentError DistSSHRun.DistSSHBase.remote_deploy_root(pwd())
        end
        old_src = string("DISTSSH_", "SOURCE_COMMIT")
        withenv(old_src => "abc") do
            @test_throws ArgumentError DistSSHRun._source_from_env()
        end
        @test DistSSHRun._reject_obsolete_pipeline_size_env(
            DistSSHRun.ProcessEnv(Dict{String, String}()),
        ) === nothing
        @test_throws ArgumentError DistSSHRun._reject_obsolete_pipeline_size_env(
            DistSSHRun.ProcessEnv(Dict(string("DISTSSH_", "SIZE_PROBE") => "1")),
        )
        @test_throws ArgumentError DistSSHRun._reject_obsolete_pipeline_size_env(
            DistSSHRun.ProcessEnv(Dict(string("DISTSSH_", "SIZE_PROBE") => "")),
        )
        withenv("DISTRIBUTED_INIT_DELAY_SEC" => "1") do
            @test_throws ArgumentError DistSSHRun._drive_init_delay_sec(; ssh = false)
        end
    end

    @testset "unparsable table numerics and bools throw" begin
        DistSSHRun.reset_worker_seeds!()
        withenv("DISTSSH_JOB_SEED" => "nope") do
            @test_throws ArgumentError DistSSHRun.job_seed()
            @test DistSSHRun._JOB_SEED[] === nothing
        end
        withenv("DISTSSH_SSH_TUNNEL" => "maybe") do
            @test_throws ArgumentError DistSSHRun.ssh_tunnel_enabled()
        end
        withenv(
            "DISTSSH_SSH_TUNNEL" => "false",
        ) do
            @test DistSSHRun.ssh_tunnel_enabled() == false
        end
        withenv("DISTSSH_SKIP_COLLECT" => "true") do
            @test DistSSHRun.DistSSHBase.env_flag(
                "DISTSSH_SKIP_COLLECT", ENV; default = false,
            )
        end
        withenv("DISTSSH_SKIP_COLLECT" => "maybe") do
            @test_throws ArgumentError DistSSHRun.DistSSHBase.env_flag(
                "DISTSSH_SKIP_COLLECT", ENV; default = false,
            )
        end
        withenv("DISTSSH_SKIP_COLLECT" => "") do
            @test_throws ArgumentError DistSSHRun.DistSSHBase.env_flag(
                "DISTSSH_SKIP_COLLECT", ENV; default = false,
            )
        end
        withenv("DISTSSH_PROGRESS_BG" => "foo") do
            @test_throws ArgumentError DistSSHRun._term_light_background()
        end
        withenv("DISTSSH_WORKER_RANK" => "nope") do
            err = try
                DistSSHRun.worker_pmap(identity, [1])
                nothing
            catch e
                e
            end
            @test err !== nothing
            @test occursin("DISTSSH_WORKER_RANK", sprint(showerror, err))
        end
        @test DistSSHRun._skip_global_worker_pkill(
            DistSSHRun.ProcessEnv(Dict("DISTSSH_SKIP_GLOBAL_WORKER_PKILL" => "true")),
        )
        @test_throws ArgumentError DistSSHRun._skip_global_worker_pkill(
            DistSSHRun.ProcessEnv(Dict("DISTSSH_SKIP_GLOBAL_WORKER_PKILL" => "maybe")),
        )
    end

    @testset "go slot permit helper bounds concurrency" begin
        inflight = Threads.Atomic{Int}(0)
        peak = Ref(0)
        lk = ReentrantLock()
        DistSSHRun._foreach_bounded(collect(1:8), 2) do _
            Threads.atomic_add!(inflight, 1)
            lock(lk) do
                peak[] = max(peak[], inflight[])
            end
            sleep(0.02)
            Threads.atomic_add!(inflight, -1)
        end
        @test peak[] <= 2
        @test peak[] >= 1
    end
end
