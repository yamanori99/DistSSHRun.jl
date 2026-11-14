using Test
using Distributed
using Pkg
using TOML
using DistSSHRun

function _env_verify_job!(proj::AbstractString)
    write(joinpath(proj, "Project.toml"), "name = \"EnvVerifyJob\"\n")
    write(
        joinpath(proj, "Manifest.toml"),
        """
        julia_version = "$(VERSION)"
        manifest_format = "2.0"
        project_hash = "0123456789abcdef0123456789abcdef01234567"
        """,
    )
    return nothing
end

function _env_verify_worker_env!(w::Integer, d::Dict{String, String})
    remotecall_fetch(w, d) do dict
        ENV["DISTSSH_TEST"] = "1"
        for (k, v) in dict
            ENV[String(k)] = String(v)
        end
        return nothing
    end
    return nothing
end

function _env_verify_worker_toml_override!(w::Integer, parent::AbstractDict, tweak::Pair{String, String})
    d = Dict{String, String}(String(k) => string(v) for (k, v) in parent)
    d[tweak[1]] = tweak[2]
    io = IOBuffer()
    TOML.print(io, d)
    _env_verify_worker_env!(
        w,
        Dict("DISTSSH_TEST_WORKER_IDENTITY_TOML" => String(take!(io))),
    )
    return nothing
end

function _env_verify_clear_worker_test_env!(w::Integer)
    remotecall_fetch(w) do
        pop!(ENV, "DISTSSH_TEST_WORKER_SNAP", nothing)
        pop!(ENV, "DISTSSH_TEST_WORKER_IDENTITY_TOML", nothing)
        return nothing
    end
    return nothing
end

function _with_one_local_worker(worker_project::Union{Nothing, AbstractString}, f::Function)
    @test nprocs() == 1
    project_flag = if worker_project === nothing
        `--startup-file=no`
    else
        `--startup-file=no --project=$(String(worker_project))`
    end
    addprocs(1; exeflags = project_flag, topology = :master_worker)
    w = only(workers())
    remotecall_fetch(w) do
        return Core.eval(Main, :(using DistSSHRun))
    end
    try
        f(w)
    finally
        w in workers() && rmprocs(w; waitfor = 5.0)
    end
    @test nprocs() == 1
    return nothing
end

function _go_identity_env(parent::AbstractDict; tweak::Pair{String, String})
    d = Dict(
        "DISTSSH_TEST_RUN_IDENTITY_VERSION" => get(parent, "version", string(VERSION)),
        "DISTSSH_TEST_RUN_IDENTITY_COMMIT" => get(
            parent, "commit", string(Base.GIT_VERSION_INFO.commit),
        ),
        "DISTSSH_TEST_RUN_IDENTITY_MAN_SHA" => get(parent, "manifest.sha256", ""),
        "DISTSSH_TEST_RUN_IDENTITY_PROJ_SHA" => get(parent, "project.sha256", ""),
    )
    key = tweak[1]
    if key == "version"
        d["DISTSSH_TEST_RUN_IDENTITY_VERSION"] = tweak[2]
    elseif key == "commit"
        d["DISTSSH_TEST_RUN_IDENTITY_COMMIT"] = tweak[2]
    elseif key == "manifest.sha256"
        d["DISTSSH_TEST_RUN_IDENTITY_MAN_SHA"] = tweak[2]
    elseif key == "project.sha256"
        d["DISTSSH_TEST_RUN_IDENTITY_PROJ_SHA"] = tweak[2]
    else
        error("unknown go identity tweak key=$(repr(key))")
    end
    return d
end

@testset "environment verify guards" begin
    @testset "controller without Manifest fails closed" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"NoManifestYet\"\n")
            ident = DistSSHRun.run_identity(proj)
            @test isempty(ident["manifest.sha256"])
            err = try
                DistSSHRun.assert_controller_manifest_for_environment_verify!(proj)
                nothing
            catch e
                e
            end
            err isa ErrorException || error("expected ErrorException")
            msg = sprint(showerror, err)
            @test occursin("what:", msg)
            @test occursin("no Manifest", msg)
            @test occursin("--unsafe-heterogeneous", msg)
            @test occursin("Pkg.instantiate", msg)
            @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
            slots = DistSSHRun.GoSlot[DistSSHRun.GoSlot(:parent, nothing, "parent")]
            @test_throws ErrorException DistSSHRun.verify_go_slots_match_job!(proj, slots)
            DistSSHRun.with_unsafe_heterogeneous(
                () -> begin
                    DistSSHRun.verify_workers_match_job!(proj)
                    DistSSHRun.verify_go_slots_match_job!(proj, slots)
                end, true,
            )
            prov = DistSSHRun.assemble_provenance()
            env = get(prov, "environment", nothing)
            @test env isa AbstractDict
            @test env["verification"] == "unverified"
            @test env["reason"] == "unsafe-heterogeneous"
        end
    end

    @testset "missing controller Manifest plus worker mismatch together" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"NoManMix\"\n")
            test_proj = Base.active_project()
            _with_one_local_worker(
                test_proj,
                function (w)
                    DistSSHRun._mark_workers_launched!([w], proj)
                    parent = DistSSHRun.run_identity(proj)
                    _env_verify_worker_toml_override!(
                        w, parent, "version" => "1.0.0",
                    )
                    err = try
                        DistSSHRun.verify_workers_match_job!(proj)
                        nothing
                    catch e
                        e
                    end
                    err isa ErrorException || error("expected ErrorException")
                    msg = sprint(showerror, err)
                    @test occursin("no Manifest", msg)
                    @test occursin("julia version", msg)
                    return nothing
                end,
            )
        end
    end

    @testset "manifest_path naming variants" begin
        _with_tempdir() do root
            julia_only = joinpath(root, "julia-only")
            mkpath(julia_only)
            write(joinpath(julia_only, "JuliaProject.toml"), "name = \"JuliaOnly\"\n")
            lock = joinpath(julia_only, "JuliaManifest.toml")
            write(lock, "# lock\n")
            @test DistSSHRun.manifest_path(julia_only) == lock
            ident = DistSSHRun.run_identity(julia_only)
            @test !isempty(ident["manifest.sha256"])
            @test ident["manifest"] == lock

            ver = joinpath(root, "ver")
            mkpath(ver)
            write(joinpath(ver, "Project.toml"), "name = \"Ver\"\n")
            vman = joinpath(
                ver, "Manifest-v$(VERSION.major).$(VERSION.minor).toml",
            )
            write(vman, "# v\n")
            @test DistSSHRun._existing_project_manifest(ver) == vman
            @test !isempty(DistSSHRun.run_identity(ver)["manifest.sha256"])

            ws = joinpath(root, "ws")
            sub = joinpath(ws, "sub")
            mkpath(sub)
            write(
                joinpath(ws, "Project.toml"),
                "name = \"WsRoot\"\n[workspace]\nmembers = [\"sub\"]\n",
            )
            root_man = joinpath(ws, "Manifest.toml")
            write(root_man, "# workspace lock\n")
            write(joinpath(sub, "Project.toml"), "name = \"SubPkg\"\n")
            sub_mp = DistSSHRun.manifest_path(sub)
            # Finding: Julia `manifest_path` on a workspace member directory may be
            # `nothing` while the root `Manifest.toml` exists (verified on 1.13).
            @test sub_mp === nothing
            @test DistSSHRun.manifest_path(ws) == root_man
            @test !isempty(DistSSHRun.run_identity(ws)["manifest.sha256"])
            DistSSHRun.assert_controller_manifest_for_environment_verify!(ws)
        end
    end

    @testset "verify_workers_match_job!" begin
        _with_tempdir() do proj
            _env_verify_job!(proj)
            old = Base.active_project()
            test_proj = old
            try
                Pkg.activate(proj; io = devnull)
                _with_one_local_worker(
                    test_proj, function (w)
                        DistSSHRun._mark_workers_launched!([w], proj)
                        remotecall_fetch(w, proj) do p
                            ENV["JULIA_PROJECT"] = String(p)
                            return nothing
                        end
                        local parent = DistSSHRun.run_identity(proj)

                        @testset "manifest.sha256" begin
                            _env_verify_worker_toml_override!(
                                w, parent, "manifest.sha256" => "c"^64,
                            )
                            @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                            DistSSHRun.with_unsafe_heterogeneous(
                                () -> DistSSHRun.verify_workers_match_job!(proj), true,
                            )
                        end
                        _env_verify_clear_worker_test_env!(w)

                        @testset "project.sha256" begin
                            _env_verify_worker_toml_override!(
                                w, parent, "project.sha256" => "d"^64,
                            )
                            @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                            DistSSHRun.with_unsafe_heterogeneous(
                                () -> DistSSHRun.verify_workers_match_job!(proj), true,
                            )
                        end
                        _env_verify_clear_worker_test_env!(w)

                        @testset "julia version" begin
                            parent = DistSSHRun.run_identity(proj)
                            _env_verify_worker_toml_override!(
                                w, parent, "version" => "1.0.0",
                            )
                            @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                            DistSSHRun.with_unsafe_heterogeneous(
                                () -> DistSSHRun.verify_workers_match_job!(proj), true,
                            )
                        end
                        _env_verify_clear_worker_test_env!(w)

                        @testset "julia commit" begin
                            parent = DistSSHRun.run_identity(proj)
                            _env_verify_worker_toml_override!(
                                w,
                                parent,
                                "commit" => "0000000000000000000000000000000000000000",
                            )
                            @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                            DistSSHRun.with_unsafe_heterogeneous(
                                () -> DistSSHRun.verify_workers_match_job!(proj), true,
                            )
                        end
                        _env_verify_clear_worker_test_env!(w)

                        @testset "non-dict worker snapshot" begin
                            _env_verify_worker_env!(
                                w,
                                Dict("DISTSSH_TEST_WORKER_SNAP" => "non_dict"),
                            )
                            @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                            DistSSHRun.with_unsafe_heterogeneous(
                                () -> DistSSHRun.verify_workers_match_job!(proj), true,
                            )
                        end
                        return nothing
                    end
                )
            finally
                old === nothing || Pkg.activate(old; io = devnull)
            end
        end
    end

    @testset "_remote_project_for_go prefers remote work root" begin
        local_proj = "/home/controller/jobs/app"
        remote_src = "/home/remote/runs/run123/src"
        @test DistSSHRun._remote_project_for_go("host1", remote_src, local_proj) == remote_src
    end

    @testset "go remote identity probe uses launch JULIA_LOAD_PATH" begin
        _with_tempdir() do state
            logp = joinpath(state, "ssh.log")
            base = _fake_setup_remote_env(state)
            env = merge(
                base,
                Dict(
                    "DISTSSH_TEST_JULIA_WHICH" => "/usr/bin/julia",
                    "DISTSSH_TEST_POSIX_SHELL" => "1",
                    "DISTSSH_TEST_SSH_LOG" => logp,
                ),
            )
            _with_tempdir() do proj
                _env_verify_job!(proj)
                withenv(env...) do
                    DistSSHRun._go_remote_run_identity("host1", proj, nothing)
                end
                script = isfile(logp) ? read(logp, String) : ""
                @test occursin("JULIA_LOAD_PATH=", script)
                @test occursin("@:@stdlib", script)
            end
        end
    end

    @testset "go remote identity keeps remote paths off the controller" begin
        _with_tempdir() do state
            logp = joinpath(state, "ssh.log")
            base = _fake_setup_remote_env(state)
            env = merge(
                base,
                Dict(
                    "DISTSSH_TEST_JULIA_WHICH" => "/usr/bin/julia",
                    "DISTSSH_TEST_POSIX_SHELL" => "1",
                    "DISTSSH_TEST_SSH_LOG" => logp,
                ),
            )
            controller_home = "/home/controller-user"
            withenv(merge(env, Dict("HOME" => controller_home))...) do
                isfile(logp) && rm(logp; force = true)
                DistSSHRun._go_remote_run_identity("host1", "~/runs/job/src", nothing)
                script = isfile(logp) ? read(logp, String) : ""
                @test occursin("--project=", script)
                @test occursin("~/", script)
                @test !occursin(controller_home, script)
                @test !occursin("/home/controller-user/runs", script)
            end
            rel = "./runs/src"
            controller_expanded = abspath(rel)
            withenv(env...) do
                isfile(logp) && rm(logp)
                DistSSHRun._go_remote_run_identity("host1", rel, nothing)
                script = isfile(logp) ? read(logp, String) : ""
                @test occursin("--project=", script)
                @test !occursin(controller_expanded, script)
                @test occursin("./runs", script) || occursin("./runs/src", script)
            end
        end
    end

    @testset "verify_go_slots_match_job! child slot" begin
        _with_tempdir() do state
            base = _fake_setup_remote_env(state)
            env = merge(
                base,
                Dict(
                    "DISTSSH_TEST_JULIA_WHICH" => "/usr/bin/julia",
                    "DISTSSH_TEST_POSIX_SHELL" => "1",
                ),
            )
            _with_tempdir() do proj
                _env_verify_job!(proj)
                parent = DistSSHRun.run_identity(proj)
                slots = DistSSHRun.GoSlot[
                    DistSSHRun.GoSlot(:child, "host1", "child-1"),
                ]
                for (name, tweak_val) in (
                        ("manifest.sha256", "c"^64),
                        ("project.sha256", "d"^64),
                        ("version", "1.0.0"),
                        ("commit", "0000000000000000000000000000000000000000"),
                    )
                    @testset "$(name)" begin
                        withenv(merge(env, _go_identity_env(parent; tweak = name => tweak_val))...) do
                            @test_throws ErrorException DistSSHRun.verify_go_slots_match_job!(
                                proj, slots; remote_root = proj,
                            )
                            DistSSHRun.with_unsafe_heterogeneous(
                                () -> DistSSHRun.verify_go_slots_match_job!(
                                    proj, slots; remote_root = proj,
                                ),
                                true,
                            )
                        end
                    end
                end
            end
        end
    end
end
