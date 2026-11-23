struct _LeakGuardProbe <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    _LeakGuardProbe(desc) = new(String(desc), Any[])
end

function Test.record(ts::_LeakGuardProbe, res::Test.Result)
    push!(ts.results, res)
    return res
end

function Test.finish(ts::_LeakGuardProbe)
    return ts
end

function _spawn_tagged_orphan(tag::AbstractString, token::AbstractString)
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    script = string(
        "nohup ",
        Base.shell_escape(julia),
        " --startup-file=no -e 'sleep(120)' -- ",
        Base.shell_escape(token),
        " >/dev/null 2>&1 &",
    )
    env = copy(ENV)
    env["DISTSSH_TEST_LEAK_TAG"] = tag
    run(setenv(`sh -c $script`, env))
    deadline = time() + 10
    rows = ProcessRow[]
    while time() < deadline
        rows = processes_with_env("DISTSSH_TEST_LEAK_TAG", tag)
        hit = any(rows) do row
            row.ppid == 1 && any(part -> part == token, split(row.command))
        end
        hit && return rows
        sleep(0.1)
    end
    return rows
end

function _stop_tagged_orphan(tag::AbstractString)
    rows = processes_with_env("DISTSSH_TEST_LEAK_TAG", tag)
    DistSSHRun.DistSSHBase.reap!(rows)
    wait_gone(() -> processes_with_env("DISTSSH_TEST_LEAK_TAG", tag); timeout = 5.0)
    return nothing
end

@testset "leak guard state" begin
    before = (env = Dict("A" => "1"), load = ["x"], proj = "/p")
    after = (env = Dict("A" => "2"), load = ["x"], proj = "/p")
    msgs = _leak_guard_state_messages(before, after)
    @test length(msgs) == 1
    @test occursin("ENV[A]", msgs[1])
    @test occursin("1", msgs[1])
    @test occursin("2", msgs[1])
end

@testset "leak guard precompile tokens" begin
    worker = ProcessRow(1, 1, "", "julia --startup-file=no --worker")
    buried = ProcessRow(1, 1, "", "julia --startup-file=no foo--worker")
    longer = ProcessRow(1, 1, "", "julia --startup-file=no --worker-extra")
    incremental = ProcessRow(1, 1, "", "julia --output-incremental -O1")
    output_o = ProcessRow(1, 1, "", "julia --output-o /tmp/out.o")
    output_o_prefix = ProcessRow(1, 1, "", "julia --output-o-extra")
    glued = ProcessRow(1, 1, "", "julia x--output-incremental")
    alive_parent = ProcessRow(1, 2, "", "julia --output-incremental")
    @test !_leak_guard_known_precompile_orphan(worker)
    @test !_leak_guard_known_precompile_orphan(buried)
    @test !_leak_guard_known_precompile_orphan(longer)
    @test _leak_guard_known_precompile_orphan(incremental)
    @test _leak_guard_known_precompile_orphan(output_o)
    @test !_leak_guard_known_precompile_orphan(output_o_prefix)
    @test !_leak_guard_known_precompile_orphan(glued)
    @test !_leak_guard_known_precompile_orphan(alive_parent)
end

@testset "leak guard orphan worker" begin
    _test_skip_unless_unix() || return
    tag = "leak-orphan-$(getpid())-$(rand(UInt32))"
    try
        rows = _spawn_tagged_orphan(tag, "--worker")
        @test any(row -> row.ppid == 1, rows)
        probe = @testset _LeakGuardProbe "tagged worker fails the guard" begin
            _assert_no_leaked_processes(tag; grace = 0.3, label = "worker orphan")
        end
        @test any(res -> res isa Test.Fail, probe.results)
        @test !any(res -> res isa Test.Pass, probe.results)
        still = processes_with_env("DISTSSH_TEST_LEAK_TAG", tag)
        @test any(row -> row.ppid == 1, still)
    finally
        _stop_tagged_orphan(tag)
    end
end

@testset "leak guard orphan precompile" begin
    _test_skip_unless_unix() || return
    tag = "leak-precompile-$(getpid())-$(rand(UInt32))"
    try
        rows = _spawn_tagged_orphan(tag, "--output-incremental")
        @test any(row -> row.ppid == 1, rows)
        _assert_no_leaked_processes(tag; grace = 0.3, label = "precompile orphan")
        still = processes_with_env("DISTSSH_TEST_LEAK_TAG", tag)
        @test any(row -> row.ppid == 1, still)
    finally
        _stop_tagged_orphan(tag)
    end
end
