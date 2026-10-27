using Test
using Distributed

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
    @test ssh_exe.exec[1] == "env"
    @test "/opt/julia" in ssh_exe.exec
    @test "-u" in ssh_exe.exec
    @test "JULIA_PROJECT" in ssh_exe.exec
    @test "JULIA_LOAD_PATH" in ssh_exe.exec
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

    pin = DistSSHRun.pin_local_julia(nothing)
    @test isabspath(pin)
    @test isfile(pin) || islink(pin)

    cookie_before = Distributed.cluster_cookie()
    DistSSHRun.ensure_run_cluster_cookie!()
    @test length(Distributed.cluster_cookie()) == 16
    @test Distributed.cluster_cookie() == cookie_before || nprocs() == 1
end
