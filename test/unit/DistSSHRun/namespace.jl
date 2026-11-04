using Test

@testset "namespace" begin
    @test DistSSHRun.cache_remote_dir("/remote/App") == joinpath(
        "/remote/App", ".distsshkit", "cache", "sha256",
    )

    _with_tempdir() do proj
        write(joinpath(proj, "Project.toml"), "name = \"CachePush\"\n")
        session = DistSSHRun.KitSession(project = proj, workers = ["parent:1"])
        @test_throws ArgumentError DistSSHRun.push_cache!(session)
        empty = DistSSHRun.KitSession(project = proj, workers = ["child:host1"])
        result = DistSSHRun.push_cache!(empty)
        @test result.ok
        @test isempty(result.hosts)
        src = joinpath(proj, "blob.bin")
        write(src, "cache-bytes")
        h = DistSSHRun.file_sha256(DistSSHRun.cache_file(src; project = proj))
        @test_throws ArgumentError DistSSHRun.push_cache!(
            DistSSHRun.KitSession(project = proj, workers = ["child:host1"]);
            hashes = ["not-a-hash"],
        )
        @test_throws ArgumentError DistSSHRun.push_cache!(
            DistSSHRun.KitSession(project = proj, workers = ["child:host1"]);
            hashes = ["a"^64],
        )
        _with_tempdir() do state_dir
            env = merge(
                _fake_setup_remote_env(state_dir),
                Dict(
                    "DISTRIBUTED_PROJECT_ROOT" => proj,
                    "DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/fake/remote/CachePush",
                ),
            )
            withenv(env...) do
                DistSSHRun.apply_kit_cli_session!(DistSSHRun.KitCliSession(quiet = true, yes = true))
                sess = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:host1"],
                    remote = "/fake/remote/CachePush",
                )
                ok = DistSSHRun.push_cache!(sess)
                @test ok.ok
                @test length(ok.hosts) == 1
                @test ok.hosts[1].ok
                subset = DistSSHRun.push_cache!(sess; hashes = [h])
                @test subset.ok
                withenv("DISTSSHKIT_TEST_CACHE_PUSH_FAIL" => "1") do
                    fail = DistSSHRun.push_cache!(sess)
                    @test !fail.ok
                    @test !fail.hosts[1].ok
                end
            end
        end
    end
end

function _cache_tar(pairs::Vector{Pair{String, Vector{UInt8}}})
    dir = mktempdir()
    for (name, body) in pairs
        write(joinpath(dir, name), body)
    end
    io = IOBuffer()
    DistSSHRun.Tar.create(dir, io)
    return take!(io)
end

function _run_cache_extract(cache::AbstractString, tar::Vector{UInt8})
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    cmd = `$(julia) --startup-file=no --compiled-modules=existing -e $(DistSSHRun._CACHE_EXTRACT_EXPR) -- $cache`
    # Same environment as the remote helper. Pkg.test leaves `JULIA_PROJECT`
    # set, and that project does not load stdlib `Tar`.
    out = IOBuffer()
    err = IOBuffer()
    proc = withenv(
        "JULIA_PROJECT" => nothing,
        "JULIA_LOAD_PATH" => "@stdlib",
        "JULIA_DEPOT_PATH" => "",
    ) do
        return open(pipeline(ignorestatus(cmd); stdout = out, stderr = err); write = true)
    end
    write(proc, tar)
    close(proc)
    wait(proc)
    return (Int(something(proc.exitcode, 1)), String(take!(out)), String(take!(err)))
end

@testset "cache tar helper" begin
    body_a = Vector{UInt8}("cache-a")
    body_b = Vector{UInt8}("cache-b")
    name_a = DistSSHRun.SHA.bytes2hex(DistSSHRun.SHA.sha256(body_a))
    name_b = DistSSHRun.SHA.bytes2hex(DistSSHRun.SHA.sha256(body_b))
    tar_a = _cache_tar([name_a => body_a])
    tar_b = _cache_tar([name_b => body_b])
    tar_both = _cache_tar([name_a => body_a, name_b => body_b])

    parent = mktempdir()
    cache = joinpath(parent, "sha256")
    stale = joinpath(parent, ".staging-99999999-old")
    mkdir(stale)
    write(joinpath(stale, "leftover"), "x")
    live = joinpath(parent, string(".staging-", getpid(), "-live"))
    mkdir(live)
    run(`touch -t 202001010000 $stale $live`)
    code, out, _ = _run_cache_extract(cache, tar_a)
    @test code == 0
    @test occursin(name_a, out)
    @test read(joinpath(cache, name_a)) == body_a
    @test !isdir(stale)
    @test isdir(live)
    @test !any(n -> startswith(n, ".staging-") && n != basename(live), readdir(parent))
    rm(live; force = true, recursive = true)

    cut = tar_both
    while length(cut) >= 512 && all(iszero, @view cut[(end - 511):end])
        cut = cut[1:(end - 512)]
    end
    # One entry, ending on its boundary, with the tar footer removed.
    first_end = 512 + (512 * cld(length(body_a), 512))
    partial = cut[1:first_end]
    edge = mktempdir()
    edge_cache = joinpath(edge, "sha256")
    code, _, err = _run_cache_extract(edge_cache, partial)
    @test code == 0
    @test isempty(err)
    got = filter(n -> n in (name_a, name_b), readdir(edge_cache))
    @test length(got) == 1

    short = partial[1:(512 + 1)]
    before = readdir(edge_cache)
    code, _, err = _run_cache_extract(edge_cache, short)
    @test code != 0
    @test occursin("truncated", err)
    @test sort(readdir(edge_cache)) == sort(before)

    bad = copy(tar_b)
    bad[513] = bad[513] == 0x00 ? 0x01 : 0x00
    code, _, err = _run_cache_extract(cache, bad)
    @test code != 0
    @test occursin("digest mismatch", err)
    @test !isfile(joinpath(cache, name_b))
    code, _, _ = _run_cache_extract(cache, tar_b)
    @test code == 0
    @test read(joinpath(cache, name_b)) == body_b

    parent2 = mktempdir()
    cache2 = joinpath(parent2, "sha256")
    c1 = @async _run_cache_extract(cache2, tar_both)
    c2 = @async _run_cache_extract(cache2, tar_a)
    code1, _, err1 = fetch(c1)
    code2, _, err2 = fetch(c2)
    @test code1 == 0
    @test code2 == 0
    @test isempty(err1)
    @test isempty(err2)
    @test read(joinpath(cache2, name_a)) == body_a
    @test read(joinpath(cache2, name_b)) == body_b
    @test !any(n -> startswith(n, ".staging-"), readdir(parent2))

    calls = Ref(0)
    names = [name_a, name_b]
    err = DistSSHRun._cache_push_pending!(names) do batch
        calls[] += 1
        if calls[] == 1
            return (1, String[batch[1]])
        end
        return (0, batch)
    end
    @test err === nothing
    @test calls[] == 2
    calls[] = 0
    err = DistSSHRun._cache_push_pending!(names) do _
        calls[] += 1
        return (1, String[])
    end
    @test err == "cache tar failed"
    @test calls[] == 2
end
