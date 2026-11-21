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
        """
    )
    return nothing
end

function _env_verify_job_distssh_pkg!(proj::AbstractString)
    _env_verify_job!(proj)
    open(joinpath(proj, "Manifest.toml"), "a") do io
        println(
            io,
            "deps = {DistSSHRun = [{uuid = \"00000000-0000-0000-0000-000000000001\", version = \"0.2.0-DEV\"}]}"
        )
    end
    return nothing
end

function _env_verify_set_snapshot!(snap)
    DistSSHRun._WORKER_ENV_SNAPSHOT_OVERRIDE[] = _ -> snap
    return nothing
end

function _env_verify_worker_toml_override!(::Integer, parent::AbstractDict, tweak::Pair{String, String})
    d = Dict{String, String}(String(k) => string(v) for (k, v) in parent)
    d[tweak[1]] = tweak[2]
    _env_verify_set_snapshot!(d)
    return nothing
end

function _env_verify_clear_worker_test_env!(::Integer)
    DistSSHRun._WORKER_ENV_SNAPSHOT_OVERRIDE[] = nothing
    return nothing
end

function _env_verify_solo_workers!()
    leftover = setdiff(collect(workers()), [1])
    isempty(leftover) || rmprocs(leftover; waitfor = 5.0)
    return nothing
end

function _env_verify_add_local_workers(
        n::Integer,
        worker_project::Union{Nothing, AbstractString} = Base.active_project(),
    )
    _env_verify_solo_workers!()
    project_flag = if worker_project === nothing
        `--startup-file=no`
    else
        `--startup-file=no --project=$(String(worker_project))`
    end
    addprocs(n; exeflags = project_flag, topology = :master_worker)
    ws = sort!(collect(workers()))
    for w in ws
        remotecall_fetch(w) do
            return Core.eval(Main, :(using DistSSHRun))
        end
    end
    return ws
end

function _with_one_local_worker(worker_project::Union{Nothing, AbstractString}, f::Function)
    _env_verify_solo_workers!()
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
            parent, "commit", string(Base.GIT_VERSION_INFO.commit)
        ),
        "DISTSSH_TEST_RUN_IDENTITY_SYSIMAGE" => get(parent, "sysimage", ""),
        "DISTSSH_TEST_RUN_IDENTITY_MAN_SHA" => get(parent, "manifest.sha256", ""),
        "DISTSSH_TEST_RUN_IDENTITY_PROJ_SHA" => get(parent, "project.sha256", "")
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

function _env_verify_guards()
    @testset "environment verify guards" begin
        _env_run_id_shipped_run_verify_tests()

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
                @test occursin("--unsafe-skip-env-digests", msg)
                @test occursin("Pkg.instantiate", msg)
                @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                slots = DistSSHRun.GoSlot[DistSSHRun.GoSlot(:parent, nothing, "parent")]
                @test_throws ErrorException DistSSHRun.verify_go_slots_match_job!(proj, slots)
                DistSSHRun.with_unsafe_skip_env_digests(
                    () -> begin
                        DistSSHRun.verify_workers_match_job!(proj)
                        DistSSHRun.verify_go_slots_match_job!(proj, slots)
                    end, true
                )
                prov = DistSSHRun.assemble_provenance()
                env = get(prov, "environment", nothing)
                @test env isa AbstractDict
                @test env["verification"] == "unverified"
                @test env["reason"] == "unsafe-skip-env-digests"
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
                            w, parent, "version" => "1.0.0"
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
                    end
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
                    ver, "Manifest-v$(VERSION.major).$(VERSION.minor).toml"
                )
                write(vman, "# v\n")
                @test DistSSHRun._existing_project_manifest(ver) == vman
                @test !isempty(DistSSHRun.run_identity(ver)["manifest.sha256"])

                ws = joinpath(root, "ws")
                sub = joinpath(ws, "sub")
                mkpath(sub)
                write(
                    joinpath(ws, "Project.toml"),
                    "name = \"WsRoot\"\n[workspace]\nmembers = [\"sub\"]\n"
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

        @testset "controller Manifest not current fails closed" begin
            _with_tempdir() do proj
                write(joinpath(proj, "Project.toml"), "name = \"Stale\"\n[deps]\nExample = \"7876af07-990d-54b4-ab0e-23690620f79a\"\n")
                write(
                    joinpath(proj, "Manifest.toml"),
                    """
                    manifest_format = "2.0"
                    julia_version = "$(VERSION)"
                    project_hash = "0123456789abcdef0123456789abcdef01234567"
                    """
                )
                @test_throws ErrorException DistSSHRun.assert_controller_manifest_current!(proj)
                err = try
                    DistSSHRun.assert_controller_environment_for_verify!(proj)
                    nothing
                catch e
                    e
                end
                err isa ErrorException || error("expected ErrorException")
                msg = sprint(showerror, err)
                @test occursin("not current", msg)
                @test occursin("unsafe-skip-env-digests does not waive", msg)
            end
        end

        @testset "manifest current without project file fails closed" begin
            _with_tempdir() do root
                bare = joinpath(root, "bare")
                mkpath(bare)
                write(joinpath(bare, "Manifest.toml"), "manifest_format = \"2.0\"\n")
                @test isempty(DistSSHRun._located_project_file_for_identity(bare))
                err = try
                    DistSSHRun.assert_controller_manifest_current!(bare)
                    nothing
                catch e
                    e
                end
                err isa ErrorException || error("expected ErrorException")
                msg = sprint(showerror, err)
                @test occursin("not current", msg)
                @test occursin("no Project.toml or JuliaProject.toml", msg)
                @test occursin("unsafe-skip-env-digests does not waive", msg)
                DistSSHRun.with_unsafe_skip_env_digests(true) do
                    @test_throws ErrorException DistSSHRun.assert_controller_manifest_current!(bare)
                end
            end
        end

        @testset "manifest current checks JuliaProject.toml tree" begin
            _with_tempdir() do root
                julia_only = joinpath(root, "julia-only")
                mkpath(julia_only)
                write(joinpath(julia_only, "JuliaProject.toml"), "name = \"JuliaOnly\"\n")
                write(
                    joinpath(julia_only, "JuliaManifest.toml"),
                    """
                    manifest_format = "2.0"
                    julia_version = "$(VERSION)"
                    project_hash = "0123456789abcdef0123456789abcdef01234567"
                    """
                )
                @test_throws ErrorException DistSSHRun.assert_controller_manifest_current!(
                    julia_only
                )
            end
        end

        @testset "run_identity records default sysimage" begin
            _with_tempdir() do proj
                _env_verify_job!(proj)
                ident = DistSSHRun.run_identity(proj)
                @test !isempty(ident["sysimage"])
                @test DistSSHRun.julia_sysimage_is_default()
                expected_sysimage = try
                    abspath(realpath(DistSSHRun.julia_sysimage_path()))
                catch
                    DistSSHRun.julia_sysimage_path()
                end
                @test ident["sysimage"] == expected_sysimage
                @test ident["sysimage.default"] == "true"
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
                                    w, parent, "manifest.sha256" => "c"^64
                                )
                                @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                                DistSSHRun.with_unsafe_skip_env_digests(
                                    () -> DistSSHRun.verify_workers_match_job!(proj), true
                                )
                            end
                            _env_verify_clear_worker_test_env!(w)

                            @testset "project.sha256" begin
                                _env_verify_worker_toml_override!(
                                    w, parent, "project.sha256" => "d"^64
                                )
                                @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                                DistSSHRun.with_unsafe_skip_env_digests(
                                    () -> DistSSHRun.verify_workers_match_job!(proj), true
                                )
                            end
                            _env_verify_clear_worker_test_env!(w)

                            @testset "julia version" begin
                                parent = DistSSHRun.run_identity(proj)
                                _env_verify_worker_toml_override!(
                                    w, parent, "version" => "1.0.0"
                                )
                                @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                                err = try
                                    DistSSHRun.with_unsafe_skip_env_digests(
                                        () -> DistSSHRun.verify_workers_match_job!(proj), true
                                    )
                                    nothing
                                catch e
                                    e
                                end
                                err isa ErrorException || error("expected ErrorException under unsafe")
                                @test occursin("julia version", sprint(showerror, err))
                            end
                            _env_verify_clear_worker_test_env!(w)

                            @testset "julia commit" begin
                                parent = DistSSHRun.run_identity(proj)
                                _env_verify_worker_toml_override!(
                                    w,
                                    parent,
                                    "commit" => "0000000000000000000000000000000000000000"
                                )
                                @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                                err = try
                                    DistSSHRun.with_unsafe_skip_env_digests(
                                        () -> DistSSHRun.verify_workers_match_job!(proj), true
                                    )
                                    nothing
                                catch e
                                    e
                                end
                                err isa ErrorException || error("expected ErrorException under unsafe")
                                msg = sprint(showerror, err)
                                @test occursin("julia commit", msg) || occursin("julia build", msg)
                            end
                            _env_verify_clear_worker_test_env!(w)

                            @testset "empty julia commit" begin
                                parent = DistSSHRun.run_identity(proj)
                                _env_verify_worker_toml_override!(w, parent, "commit" => "")
                                @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                                err = try
                                    DistSSHRun.with_unsafe_skip_env_digests(
                                        () -> DistSSHRun.verify_workers_match_job!(proj), true
                                    )
                                    nothing
                                catch e
                                    e
                                end
                                err isa ErrorException || error("expected ErrorException under unsafe")
                                @test occursin("cannot determine the Julia build", sprint(showerror, err))
                            end
                            _env_verify_clear_worker_test_env!(w)

                            @testset "pkg.DistSSHRun" begin
                                _env_verify_job_distssh_pkg!(proj)
                                parent = DistSSHRun.run_identity(proj)
                                @test haskey(parent, "pkg.DistSSHRun")
                                _env_verify_worker_toml_override!(
                                    w, parent, "pkg.DistSSHRun" => "9.9.9"
                                )
                                @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                                err = try
                                    DistSSHRun.with_unsafe_skip_env_digests(
                                        () -> DistSSHRun.verify_workers_match_job!(proj), true
                                    )
                                    nothing
                                catch e
                                    e
                                end
                                err isa ErrorException || error("expected ErrorException under unsafe")
                                @test occursin("pkg.DistSSHRun", sprint(showerror, err))
                            end
                            _env_verify_clear_worker_test_env!(w)

                            @testset "manifest digest waived under unsafe" begin
                                parent = DistSSHRun.run_identity(proj)
                                _env_verify_worker_toml_override!(
                                    w, parent, "manifest.sha256" => "c"^64
                                )
                                @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                                DistSSHRun.with_unsafe_skip_env_digests(
                                    () -> begin
                                        DistSSHRun.verify_workers_match_job!(proj)
                                        prov = DistSSHRun.assemble_provenance()
                                        env = get(prov, "environment", nothing)
                                        @test env isa AbstractDict
                                        @test env["verification"] == "unverified"
                                        @test env["reason"] == "unsafe-skip-env-digests"
                                    end,
                                    true
                                )
                            end
                            _env_verify_clear_worker_test_env!(w)

                            @testset "non-dict worker snapshot" begin
                                _env_verify_set_snapshot!(42)
                                @test_throws ErrorException DistSSHRun.verify_workers_match_job!(proj)
                                @test_throws ErrorException DistSSHRun.with_unsafe_skip_env_digests(true) do
                                    DistSSHRun.verify_workers_match_job!(proj)
                                end
                            end
                            _env_verify_clear_worker_test_env!(w)
                            return nothing
                        end
                    )
                finally
                    old === nothing || Pkg.activate(old; io = devnull)
                end
            end
        end

        @testset "production worker snapshot reads Manifest pkg versions" begin
            # The installed package tree has no Manifest (`Manifest.toml` is
            # not in the git tree). The job is a project whose Manifest lists
            # DistSSHRun, which is what a registry install resolves.
            _with_tempdir() do proj
                _env_verify_job_distssh_pkg!(proj)
                parent = DistSSHRun.run_identity(proj)
                @test haskey(parent, "pkg.DistSSHRun")
                parent_ver = get(parent, "pkg.DistSSHRun", "")
                @test !isempty(parent_ver)
                @test parent_ver == "0.2.0-DEV"
                flags = DistSSHRun.worker_exeflag_strings(proj)
                env = Dict(DistSSHRun.worker_env_pairs(proj))
                addprocs(1; exeflags = Cmd(flags), env = env)
                w = only(workers())
                try
                    snap = remotecall_fetch(
                        Core.eval, w, Main, DistSSHRun._worker_identity_expr()
                    )
                    @test snap isa AbstractDict
                    @test haskey(snap, "pkg.DistSSHRun")
                    snap_ver = get(snap, "pkg.DistSSHRun", "")
                    @test !isempty(snap_ver)
                    @test snap_ver == parent_ver
                    @test get(snap, "manifest.sha256", "") == get(parent, "manifest.sha256", "")
                    lines = DistSSHRun.identity_mismatches(parent, snap)
                    @test isempty(lines)
                finally
                    w in workers() && rmprocs(w; waitfor = 5.0)
                end
                return nothing
            end
        end

        @testset "snapshot fetch failure is reported with other mismatches" begin
            _with_tempdir() do proj
                _env_verify_job!(proj)
                test_proj = Base.active_project()
                _with_one_local_worker(
                    test_proj,
                    function (w)
                        DistSSHRun._mark_workers_launched!([w], proj)
                        DistSSHRun._WORKER_ENV_SNAPSHOT_OVERRIDE[] = _ -> error("snap boom")
                        try
                            err = try
                                DistSSHRun.verify_workers_match_job!(proj)
                                nothing
                            catch e
                                e
                            end
                            err isa ErrorException || error("expected ErrorException")
                            msg = sprint(showerror, err)
                            @test occursin("snapshot failed:", msg)
                            @test occursin("snap boom", msg)
                            @test occursin("pid=$(w)", msg)
                        finally
                            DistSSHRun._WORKER_ENV_SNAPSHOT_OVERRIDE[] = nothing
                        end
                        return nothing
                    end
                )
            end
        end

        @testset "project identity script reads pkg versions" begin
            _with_tempdir() do proj
                _env_verify_job_distssh_pkg!(proj)
                bin = joinpath(Sys.BINDIR, "julia")
                # `Pkg.test` sets `JULIA_LOAD_PATH` to `@` plus this test
                # directory, which does not include `@stdlib`. The go probe
                # sets the launch path, and that path is what resolves
                # `using SHA, TOML` on a job project that does not list them.
                cmd = addenv(
                    `$bin --startup-file=no --project=$proj -e $(DistSSHRun._PROJECT_IDENTITY_EVAL)`,
                    "JULIA_LOAD_PATH" => DistSSHRun._LAUNCH_LOAD_PATH
                )
                out = read(cmd, String)
                @test occursin("pkg.DistSSHRun=0.2.0-DEV", out)
                @test occursin("version=$(VERSION)", out)
                @test occursin("commit=", out)
            end
        end

        @testset "failed identity probe is not an empty commit" begin
            parent = Dict(
                "version" => "1.13.0",
                "commit" => "abc",
                "manifest.sha256" => "a"^64,
                "project.sha256" => "b"^64
            )
            worker = Dict(
                "probe_error" => "identity probe failed on host h (exit 1)\nnot a julia",
                "version" => "",
                "commit" => ""
            )
            lines = DistSSHRun._described_identity_lines(
                parent, worker, "host h"; unsafe_skip_env_digests = false
            )
            @test length(lines) == 1
            @test occursin("exit 1", only(lines))
            @test occursin("not a julia", only(lines))
            @test !occursin("cannot determine the Julia build", only(lines))
        end

        @testset "go parent slot surfaces probe_error like child slots" begin
            parent = Dict(
                "version" => string(VERSION),
                "commit" => string(Base.GIT_VERSION_INFO.commit),
                "manifest.sha256" => "a"^64,
                "project.sha256" => "b"^64
            )
            local_id = Dict(
                "probe_error" => "identity probe failed on host parent (exit 127)\nbad julia",
                "version" => "",
                "commit" => ""
            )
            direct = String[
                "parent slot: $(line)"
                    for line in DistSSHRun.identity_mismatches(
                        parent, local_id; unsafe_skip_env_digests = false
                    )
            ]
            described = DistSSHRun._described_identity_lines(
                parent, local_id, "parent slot"; unsafe_skip_env_digests = false
            )
            @test length(described) == 1
            @test occursin("exit 127", only(described))
            @test any(occursin("cannot determine the Julia build", line) for line in direct)
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
                        "DISTSSH_TEST_SSH_LOG" => logp
                    )
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
                        "DISTSSH_TEST_SSH_LOG" => logp
                    )
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
                spaced = "~/runs/with spaces/src"
                withenv(env...) do
                    isfile(logp) && rm(logp)
                    DistSSHRun._go_remote_run_identity("host1", spaced, nothing)
                    script = isfile(logp) ? read(logp, String) : ""
                    pr = DistSSHRun._remote_shell_path_word(spaced)
                    @test occursin("--project=$(pr)", script)
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
                        "DISTSSH_TEST_POSIX_SHELL" => "1"
                    )
                )
                _with_tempdir() do proj
                    _env_verify_job!(proj)
                    parent = DistSSHRun.run_identity(proj)
                    slots = DistSSHRun.GoSlot[
                        DistSSHRun.GoSlot(:child, "host1", "child-1"),
                    ]
                    for (name, tweak_val, unsafe_ok) in (
                            ("manifest.sha256", "c"^64, true),
                            ("project.sha256", "d"^64, true),
                            ("version", "1.0.0", false),
                            ("commit", "0000000000000000000000000000000000000000", false),
                        )
                        @testset "$(name)" begin
                            withenv(merge(env, _go_identity_env(parent; tweak = name => tweak_val))...) do
                                @test_throws ErrorException DistSSHRun.verify_go_slots_match_job!(
                                    proj, slots; remote_root = proj
                                )
                                if unsafe_ok
                                    DistSSHRun.with_unsafe_skip_env_digests(
                                        () -> DistSSHRun.verify_go_slots_match_job!(
                                            proj, slots; remote_root = proj
                                        ),
                                        true
                                    )
                                else
                                    @test_throws ErrorException DistSSHRun.with_unsafe_skip_env_digests(
                                        () -> DistSSHRun.verify_go_slots_match_job!(
                                            proj, slots; remote_root = proj
                                        ),
                                        true
                                    )
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return nothing
end

function _env_verify_activate_worker!(w::Integer, proj::AbstractString)
    p = String(proj)
    expr = :(
        begin
            using Pkg
            Pkg.activate($(QuoteNode(p)); io = devnull)
            nothing
        end
    )
    remotecall_fetch(Core.eval, w, Main, expr)
    return nothing
end

function _env_run_id_deploy_record!(proj::AbstractString, rid::AbstractString)
    pack = DistSSHRun._pack_project_tree(proj)
    try
        digest_rows = Any[
            Dict{String, Any}("path" => p, "blob" => h) for (p, h) in pack.content_file_digests
        ]
        rec = DistSSHRun.build_deploy_record(
            proj,
            :ship_tree;
            deploy_id = rid,
            run_id = rid,
            content_tree_hash = pack.content_tree_hash,
            content_file_digests = digest_rows,
        )
        DistSSHRun._set_active_deploy_record!(rec)
        return DistSSHRun.run_identity(proj)
    finally
        rm(pack.directory; recursive = true, force = true)
    end
end

function _env_run_id_shipped_run_verify_tests()
    @testset "verify_workers_match_shipped_run!" begin
        rid = "20260101T000000Z-aaaaaa"
        @testset "matching deploy record" begin
            _with_tempdir() do proj
                _env_verify_job!(proj)
                test_proj = Base.active_project()
                try
                    _with_one_local_worker(
                        test_proj,
                        function (w)
                            _env_verify_activate_worker!(w, proj)
                            _env_run_id_deploy_record!(proj, rid)
                            DistSSHRun._mark_workers_launched!([w], proj)
                            DistSSHRun.verify_workers_match_shipped_run!(proj; run_id = rid)
                            return nothing
                        end
                    )
                finally
                    DistSSHRun._clear_active_deploy_record!()
                end
            end
        end
        @testset "worker Project.toml byte tamper" begin
            _with_tempdir() do proj
                _env_verify_job!(proj)
                test_proj = Base.active_project()
                try
                    _with_one_local_worker(
                        test_proj,
                        function (w)
                            _env_verify_activate_worker!(w, proj)
                            _env_run_id_deploy_record!(proj, rid)
                            DistSSHRun._mark_workers_launched!([w], proj)
                            remotecall_fetch(w) do
                                pf = Base.active_project()
                                pf === nothing && error("worker has no active project")
                                path = isfile(pf) ? String(pf) : joinpath(String(pf), "Project.toml")
                                open(path, "r+") do io
                                    seekend(io)
                                    write(io, UInt8(' '))
                                end
                                return nothing
                            end
                            err = try
                                DistSSHRun.verify_workers_match_shipped_run!(proj; run_id = rid)
                                ""
                            catch e
                                sprint(showerror, e)
                            end
                            @test occursin("project.sha256", err)
                            deploy = match(r"deploy=([0-9a-f]+)", err)
                            worker = match(r"worker=([0-9a-f]+)", err)
                            @test deploy !== nothing
                            @test worker !== nothing
                            @test length(deploy.captures[1]) == length(worker.captures[1])
                            return nothing
                        end
                    )
                finally
                    DistSSHRun._clear_active_deploy_record!()
                end
            end
        end
        @testset "unsafe skip env digests" begin
            _with_tempdir() do proj
                _env_verify_job!(proj)
                test_proj = Base.active_project()
                try
                    _with_one_local_worker(
                        test_proj,
                        function (w)
                            parent = DistSSHRun.run_identity(proj)
                            _env_run_id_deploy_record!(proj, rid)
                            DistSSHRun._mark_workers_launched!([w], proj)
                            other = copy(parent)
                            other["project.sha256"] = repeat("f", 64)
                            DistSSHRun._WORKER_ENV_SNAPSHOT_OVERRIDE[] = _ -> other
                            try
                                DistSSHRun.with_unsafe_skip_env_digests(
                                    () -> DistSSHRun.verify_workers_match_shipped_run!(
                                        proj; run_id = rid
                                    ),
                                    true
                                )
                            finally
                                DistSSHRun._WORKER_ENV_SNAPSHOT_OVERRIDE[] = nothing
                            end
                            return nothing
                        end
                    )
                finally
                    DistSSHRun._clear_active_deploy_record!()
                end
            end
        end
        @testset "heterogeneous worker digests" begin
            _with_tempdir() do proj
                _env_verify_job!(proj)
                test_proj = Base.active_project()
                try
                    ws = _env_verify_add_local_workers(2, test_proj)
                    parent = _env_run_id_deploy_record!(proj, rid)
                    DistSSHRun._mark_workers_launched!(ws, proj)
                    other = copy(parent)
                    other["manifest.sha256"] = repeat("a", 64)
                    DistSSHRun._WORKER_ENV_SNAPSHOT_OVERRIDE[] =
                        pid -> pid == ws[1] ? parent : other
                    try
                        @test_throws ErrorException DistSSHRun.verify_workers_match_shipped_run!(
                            proj; run_id = rid
                        )
                    finally
                        DistSSHRun._WORKER_ENV_SNAPSHOT_OVERRIDE[] = nothing
                    end
                finally
                    _env_verify_solo_workers!()
                    DistSSHRun._clear_active_deploy_record!()
                end
            end
        end
        @testset "digest mismatch vs deploy record" begin
            _with_tempdir() do proj
                _env_verify_job!(proj)
                test_proj = Base.active_project()
                try
                    _with_one_local_worker(
                        test_proj,
                        function (w)
                            _env_verify_activate_worker!(w, proj)
                            pack = DistSSHRun._pack_project_tree(proj)
                            digest_rows = try
                                Any[
                                    Dict{String, Any}("path" => p, "blob" => h)
                                        for (p, h) in pack.content_file_digests
                                ]
                            finally
                                rm(pack.directory; recursive = true, force = true)
                            end
                            rec = DistSSHRun.build_deploy_record(
                                proj,
                                :ship_tree;
                                deploy_id = rid,
                                run_id = rid,
                                content_file_digests = digest_rows,
                            )
                            rec["project_hash"] = repeat("b", 64)
                            DistSSHRun._set_active_deploy_record!(rec)
                            DistSSHRun._mark_workers_launched!([w], proj)
                            @test_throws ErrorException DistSSHRun.verify_workers_match_shipped_run!(
                                proj; run_id = rid
                            )
                            return nothing
                        end
                    )
                finally
                    DistSSHRun._clear_active_deploy_record!()
                end
            end
        end
        @testset "last-ship.toml does not substitute deploy record" begin
            _with_tempdir() do proj
                _env_verify_job!(proj)
                env = DistSSHRun.resolve_pkg_env(proj)
                DistSSHRun.write_last_ship_record!(
                    env.env_dir,
                    proj,
                    ["host1"],
                    "20260102T000000Z-bbbbbb",
                )
                DistSSHRun._clear_active_deploy_record!()
                @test_throws ErrorException DistSSHRun.verify_workers_match_shipped_run!(
                    proj; run_id = rid
                )
            end
        end
        @testset "explicit run_id must match active deploy record run_id" begin
            _with_tempdir() do proj
                _env_verify_job!(proj)
                _env_run_id_deploy_record!(proj, rid)
                @test_throws ErrorException DistSSHRun.verify_workers_match_shipped_run!(
                    proj; run_id = "20260102T000000Z-bbbbbb"
                )
                DistSSHRun._clear_active_deploy_record!()
            end
        end
        @testset "missing manifest_hash on deploy record" begin
            _with_tempdir() do proj
                _env_verify_job!(proj)
                rec = Dict{String, Any}(
                    "writer" => DistSSHRun.run_record_writer(),
                    "mode" => "ship-tree",
                    "run_id" => rid,
                    "project_hash" => "a"^64,
                )
                DistSSHRun._set_active_deploy_record!(rec)
                try
                    @test_throws ErrorException DistSSHRun.verify_workers_match_shipped_run!(
                        proj; run_id = rid
                    )
                finally
                    DistSSHRun._clear_active_deploy_record!()
                end
            end
        end
    end
    return nothing
end

_env_verify_guards()
