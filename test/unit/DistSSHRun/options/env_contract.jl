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
                    name == "JULIA_DISTRIBUTED_EXE" && continue
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
                        name == "JULIA_DISTRIBUTED_EXE" && continue
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
