#!/usr/bin/env julia
# Real SSH: run DistSSHSize on the docker-ssh child. Not part of Pkg.test().
#
#   testenv/docker-ssh/scripts/up.sh
#   DISTSSHKIT_SSH_E2E=1 julia --project=lib/DistSSHSize lib/DistSSHSize/test/e2e.jl
#
# The child image has Julia and SSH. This file copies the DistSSHBase and
# DistSSHSize sources over that SSH channel and loads them with a manifest
# of path dependencies. It does not change the image or install a registry
# package.

using Test
using DistSSHBase
using DistSSHSize

if get(ENV, "DISTSSHKIT_SSH_E2E", "") != "1"
    @info "Skipping SSH E2E (set DISTSSHKIT_SSH_E2E=1 to enable)"
    exit(0)
end

const _ssh_config = abspath(
    joinpath(
        @__DIR__, "..", "..", "..", "testenv", "docker-ssh", ".generated", "ssh_config",
    )
)
isfile(_ssh_config) ||
    error("docker-ssh not ready: missing $(_ssh_config). Run testenv/docker-ssh/scripts/up.sh")

const _child = "child-1"
const _remote_root = "/tmp/distsshsize-e2e"

"""Manifest so the child loads the copied path packages without a registry."""
function _size_e2e_manifest()::String
    return """
    manifest_format = "2.1"

    [[deps.DistSSHBase]]
    deps = ["SHA"]
    path = "../DistSSHBase"
    uuid = "f0a69307-14e5-4272-8c28-20680d05bac8"
    version = "0.1.0"

    [[deps.DistSSHSize]]
    deps = ["DistSSHBase"]
    path = "."
    uuid = "17f52fb7-f663-4779-9b89-d421e48561db"
    version = "0.1.0"

    [[deps.SHA]]
    uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
    version = "1.0.0"
    """
end

"""Copy `lib/DistSSHBase` and `lib/DistSSHSize` to the child and add the manifest."""
function _size_e2e_ship!(host::AbstractString)
    lib = abspath(joinpath(@__DIR__, "..", ".."))
    stage = mktempdir()
    try
        cp(joinpath(lib, "DistSSHBase"), joinpath(stage, "DistSSHBase"))
        cp(joinpath(lib, "DistSSHSize"), joinpath(stage, "DistSSHSize"))
        write(joinpath(stage, "DistSSHSize", "Manifest.toml"), _size_e2e_manifest())
        remote = "rm -rf $(DistSSHBase.posix_quote(_remote_root)) && mkdir -p $(DistSSHBase.posix_quote(_remote_root)) && tar -xzf - -C $(DistSSHBase.posix_quote(_remote_root))"
        ssh = `ssh -F $_ssh_config -o RequestTTY=no $host $remote`
        run(pipeline(`tar -C $stage -czf - DistSSHBase DistSSHSize`, ssh))
    finally
        rm(stage; recursive = true, force = true)
    end
    return nothing
end

function _size_e2e_remote_script()::String
    return """
    using DistSSHSize
    res = DistSSHSize.get_local_resources()
    avail = res.total_gb * DistSSHSize.DEFAULT_MEM_HEADROOM - DistSSHSize.DEFAULT_PARENT_GB
    pw = avail > 1.0 ? 1.0 : avail * 0.5
    plan = DistSSHSize.compute_worker_plan(
        ["parent"], String[], Dict("parent" => pw),
    )
    println("TOTAL_GB=", res.total_gb)
    println("NPROC=", res.nproc)
    println("PW=", pw)
    println("PARENT_WORKERS=", plan.parent_workers)
    """
end

function _size_e2e_parse(out::AbstractString)::NamedTuple
    got = Dict{String, String}()
    for line in eachline(IOBuffer(String(out)))
        occursin('=', line) || continue
        k, v = split(line, '='; limit = 2)
        got[String(k)] = String(v)
    end
    for key in ("TOTAL_GB", "NPROC", "PW", "PARENT_WORKERS")
        haskey(got, key) || error("child stdout missing $key:\n$out")
    end
    return (
        total_gb = parse(Float64, got["TOTAL_GB"]),
        nproc = parse(Int, got["NPROC"]),
        pw = parse(Float64, got["PW"]),
        parent_workers = parse(Int, got["PARENT_WORKERS"]),
    )
end

@testset "DistSSHSize SSH" verbose = true begin
    withenv("DISTRIBUTED_SSH_OPTS" => "-F $(_ssh_config) -o RequestTTY=no") do
        _size_e2e_ship!(_child)
        project = "$_remote_root/DistSSHSize"
        script = _size_e2e_remote_script()
        out_io = IOBuffer()
        err_io = IOBuffer()
        proc = redirect_stdout(out_io) do
            redirect_stderr(err_io) do
                run_on_host(_child, ["--startup-file=no", "--project=$project", "-e", script])
            end
        end
        out = String(take!(out_io))
        err = String(take!(err_io))
        proc.exitcode == 0 ||
            error("child DistSSHSize exited $(proc.exitcode)\nstdout:\n$out\nstderr:\n$err")
        got = _size_e2e_parse(out)
        @test got.total_gb > 0
        @test got.total_gb < 16384
        @test 1 <= got.nproc <= 4096
        expected = DistSSHSize.size_worker_count(
            got.total_gb, got.nproc, got.pw; is_parent = true,
        )
        @test got.parent_workers == expected
        @test got.parent_workers > 0
    end
end
