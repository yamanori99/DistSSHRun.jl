using Test
using Distributed
using Pkg
using TOML

@testset "worker launch helper" begin
    flags = DistSSHRun.worker_exeflag_strings("/tmp/job"; local_cpu = false)
    @test "--project=/tmp/job" in flags
    @test "--startup-file=no" in flags
    @test "--history-file=no" in flags
    @test any(startswith(f, "--threads=") for f in flags)
    @test !any(startswith(f, "-C") for f in flags)

    env = Dict(DistSSHRun.worker_env_pairs("/tmp/job"))
    @test env["JULIA_LOAD_PATH"] == DistSSHRun.worker_load_path()
    @test DistSSHRun.worker_load_path(; ssh = true) == "@:@stdlib"
    @test startswith(DistSSHRun.worker_load_path(), "@:@stdlib")
    @test !occursin("@v#.#", DistSSHRun.worker_load_path())
    let ap = Base.active_project()
        ap === nothing || @test occursin(dirname(String(ap)), DistSSHRun.worker_load_path())
    end
    @test env["JULIA_PROJECT"] == "/tmp/job"
    @test haskey(env, "JULIA_NUM_THREADS")

    names = DistSSHRun.launch_override_names(
        Dict("JULIA_PROJECT" => "/old", "JULIA_LOAD_PATH" => "@v1.13"),
    )
    @test "JULIA_PROJECT" in names
    @test "JULIA_LOAD_PATH" in names
    notice = DistSSHRun.launch_override_notice("lab", names)
    @test startswith(notice, "lab: launch overrides ")

    ssh_exe = DistSSHRun.ssh_worker_exename("/opt/julia")
    ssh_cmd = join(ssh_exe.exec, " ")
    @test ssh_exe.exec[1] == "env"
    @test "/opt/julia" in ssh_exe.exec
    @test "-u" in ssh_exe.exec
    @test "JULIA_PROJECT" in ssh_exe.exec
    @test "JULIA_LOAD_PATH=@:@stdlib" in ssh_exe.exec
    @test occursin("-u JULIA_PROJECT", ssh_cmd)
    @test occursin("JULIA_LOAD_PATH=@:@stdlib /opt/julia", ssh_cmd)
    @test !occursin("-u JULIA_LOAD_PATH", ssh_cmd)
    @test DistSSHRun.ssh_addprocs_bind_localhost("user@lab") == "user@lab 127.0.0.1"

    prefix = DistSSHRun.go_remote_julia_prefix("julia")
    @test occursin("env -u JULIA_PROJECT", prefix)
    @test occursin("JULIA_LOAD_PATH=", prefix)
    @test occursin("--project=.", prefix)

    @test DistSSHRun.parse_allow_mismatch("julia,distssh") == [:julia, :distssh]
    @test DistSSHRun.parse_allow_mismatch(" manifest ") == [:manifest]
    @test_throws ArgumentError DistSSHRun.parse_allow_mismatch("cpu")
    dest = Symbol[]
    DistSSHRun.merge_allow_mismatch!(dest, "julia")
    DistSSHRun.merge_allow_mismatch!(dest, "julia,manifest")
    @test dest == [:julia, :manifest]

    parent = Dict(
        "version" => "1.13.0",
        "commit" => "abc",
        "manifest" => "/job/Manifest.toml",
        "pkg.DistSSHRun" => "0.1.0",
    )
    worker = Dict(
        "version" => "1.13.1",
        "commit" => "abc",
        "manifest" => "/job/Manifest.toml",
        "pkg.DistSSHRun" => "0.1.0",
    )
    lines = DistSSHRun._identity_mismatch_lines(
        parent, worker;
        shipped_manifest = "/job/Manifest.toml",
    )
    @test any(occursin("julia version", l) for l in lines)
    allowed = DistSSHRun._identity_mismatch_lines(
        parent, worker;
        allow = [:julia],
        shipped_manifest = "/job/Manifest.toml",
    )
    @test isempty(allowed)

    @test DistSSHRun.allow_mismatch_argv([:julia, :manifest]) ==
        ["--allow-mismatch", "julia,manifest"]

    missing_man = Dict(
        "version" => "1.13.1",
        "commit" => "abc",
        "manifest" => "",
        "pkg.DistSSHRun" => "0.1.0",
    )
    miss = DistSSHRun._identity_mismatch_lines(
        parent, missing_man;
        shipped_manifest = "/remote/job/Manifest.toml",
    )
    @test any(occursin("manifest missing", l) for l in miss)
    waived_man = DistSSHRun._identity_mismatch_lines(
        parent, missing_man;
        allow = [:manifest],
        shipped_manifest = "/remote/job/Manifest.toml",
    )
    @test !any(occursin("manifest", l) for l in waived_man)

    julia_man = DistSSHRun._identity_mismatch_lines(
        parent,
        Dict(
            "version" => "1.13.1",
            "commit" => "abc",
            "manifest" => "/job/JuliaManifest.toml",
            "pkg.DistSSHRun" => "0.1.0",
        );
        shipped_manifest = "/job/Manifest.toml",
    )
    @test any(occursin("manifest path", l) for l in julia_man)

    none = DistSSHRun._identity_mismatch_lines(
        Dict(
            "version" => "1.13.1",
            "commit" => "abc",
            "manifest" => "",
            "pkg.DistSSHRun" => "0.1.0",
        ),
        Dict(
            "version" => "1.13.1",
            "commit" => "abc",
            "manifest" => "",
            "pkg.DistSSHRun" => "0.1.0",
        );
        shipped_manifest = "",
    )
    @test !any(occursin("manifest", l) for l in none)

    pin = DistSSHRun.pin_local_julia(nothing)
    @test isabspath(pin)
    @test isfile(pin) || islink(pin)

    cookie_before = Distributed.cluster_cookie()
    DistSSHRun.ensure_run_cluster_cookie!()
    @test length(Distributed.cluster_cookie()) == 16
    @test Distributed.cluster_cookie() == cookie_before || nprocs() == 1

    _with_tempdir() do proj
        man = joinpath(proj, "Manifest.toml")
        write(
            man, """
            # This file is machine-generated - editing it directly is not advised

            julia_version = "1.13.1"
            manifest_format = "2.0"
            project_hash = "0123456789abcdef0123456789abcdef01234567"

            [[deps.Artifacts]]
            uuid = "56c22d13-8852-41a3-930b-5e04c8691e1d"

            [[deps.DistSSHKit]]
            uuid = "ceec0504-c968-4be5-b215-667cae0e8f81"
            version = "0.9.0"

            [[deps.DistSSHRun]]
            uuid = "b568025c-2759-4ef1-8b14-17d00e2cd000"
            version = "0.1.16"
            """,
        )
        parsed = TOML.parsefile(man)
        @test parsed["manifest_format"] == "2.0"
        @test parsed["deps"]["DistSSHRun"] isa Vector
        vers = DistSSHRun._distssh_versions_from_manifest(man)
        @test vers["DistSSHRun"] == "0.1.16"
        @test vers["DistSSHKit"] == "0.9.0"
        write(joinpath(proj, "Project.toml"), "name = \"Fmt2Job\"\n")
        old = Base.active_project()
        try
            Pkg.activate(proj; io = devnull)
            snap = Core.eval(Main, DistSSHRun._worker_identity_expr())
            @test snap isa AbstractDict
            @test snap["pkg.DistSSHRun"] == "0.1.16"
            @test snap["pkg.DistSSHKit"] == "0.9.0"
        finally
            old === nothing || Pkg.activate(old; io = devnull)
        end
        slots = DistSSHRun.GoSlot[DistSSHRun.GoSlot(:parent, nothing, "parent")]
        DistSSHRun.verify_go_slots_match_job!(proj, slots)
    end

    _with_tempdir() do proj
        write(joinpath(proj, "Project.toml"), "name = \"VerMan\"\n")
        write(
            joinpath(proj, "Manifest.toml"), """
            julia_version = "1.12.0"
            manifest_format = "2.0"
            project_hash = "0123456789abcdef0123456789abcdef01234567"

            [[deps.DistSSHRun]]
            uuid = "b568025c-2759-4ef1-8b14-17d00e2cd000"
            version = "0.0.1"
            """
        )
        vman = joinpath(
            proj,
            "Manifest-v$(VERSION.major).$(VERSION.minor).toml",
        )
        write(
            vman, """
            julia_version = "$(VERSION)"
            manifest_format = "2.0"
            project_hash = "0123456789abcdef0123456789abcdef01234567"

            [[deps.DistSSHRun]]
            uuid = "b568025c-2759-4ef1-8b14-17d00e2cd000"
            version = "0.1.16"
            """
        )
        @test DistSSHRun._existing_project_manifest(proj) == vman
        old = Base.active_project()
        try
            Pkg.activate(proj; io = devnull)
            snap = Core.eval(Main, DistSSHRun._worker_identity_expr())
            @test snap["manifest"] == vman
            @test snap["pkg.DistSSHRun"] == "0.1.16"
        finally
            old === nothing || Pkg.activate(old; io = devnull)
        end
    end
end
