using Test

function _plan_each_subexpr(f, ex)
    ex isa LineNumberNode && return nothing
    f(ex)
    ex isa Expr || return nothing
    for a in ex.args
        _plan_each_subexpr(f, a)
    end
    return nothing
end

@testset "plan" begin
    _with_tempdir() do tmp
        map_path = joinpath(tmp, "mapped.jl")
        write(
            map_path, """
            f(x) = x + 1
            map(f, 1:8)
            """
        )
        kp = DistSSHRun.plan(map_path)
        @test kp.ok
        @test kp.suggest === :ride
        @test any(f -> f.kind === :map && f.status === :candidate, kp.findings)
        @test kp.julia == string(VERSION)
        @test :plan! ∉ names(DistSSHRun)

        filt_path = joinpath(tmp, "filt.jl")
        write(filt_path, "filter(iseven, 1:10)\n")
        @test DistSSHRun.plan(filt_path).suggest === :ride

        comp_path = joinpath(tmp, "comp.jl")
        write(comp_path, "ys = [x^2 for x in 1:4]\n")
        kc = DistSSHRun.plan(comp_path)
        @test kc.suggest === :ride
        @test any(f -> f.kind === :comprehension, kc.findings)

        for_path = joinpath(tmp, "loop.jl")
        write(
            for_path, """
            xs = 1:3
            results = similar(collect(xs))
            for i in eachindex(xs)
                results[i] = xs[i]
            end
            """
        )
        kf = DistSSHRun.plan(for_path)
        @test kf.suggest === :ride
        @test any(f -> f.kind === :for && f.status === :candidate, kf.findings)
        buf = IOBuffer()
        DistSSHRun.print_plan(kf; io = buf)
        @test occursin("suggest:  ride", String(take!(buf)))

        acc_path = joinpath(tmp, "acc.jl")
        write(
            acc_path, """
            s = 0
            for x in 1:3
                s += x
            end
            """
        )
        ka = DistSSHRun.plan(acc_path)
        @test ka.suggest === :go
        @test any(f -> f.kind === :for && f.status === :out_of_scope, ka.findings)

        stenc_path = joinpath(tmp, "stenc.jl")
        write(
            stenc_path, """
            dest = [1, 2, 3]
            alias = dest
            for i in 2:length(dest)
                dest[i] = alias[i - 1]
            end
            """
        )
        ks = DistSSHRun.plan(stenc_path)
        @test ks.suggest === :go
        @test any(f -> f.kind === :for && f.status === :out_of_scope, ks.findings)

        drive_path = joinpath(tmp, "driver.jl")
        write(
            drive_path, """
            using Distributed
            pmap(x -> x^2, 1:4)
            """
        )
        kd = DistSSHRun.plan(drive_path)
        @test kd.suggest === :drive
        @test any(f -> f.status === :drive_vocab, kd.findings)

        every_path = joinpath(tmp, "every.jl")
        write(every_path, "@everywhere foo() = 1\n")
        @test DistSSHRun.plan(every_path).suggest === :drive

        plain_path = joinpath(tmp, "plain.jl")
        write(plain_path, "println(2 + 2)\n")
        @test DistSSHRun.plan(plain_path).suggest === :go

        missing = DistSSHRun.plan(joinpath(tmp, "nope.jl"))
        @test !missing.ok
        missing_error = missing.error
        @test missing_error !== nothing
        @test occursin("file not found", missing_error)
        @test missing.slots === nothing

        @test DistSSHRun.plan(map_path).slots === nothing
        sized = with_kit_verbosity(:progress) do
            DistSSHRun.plan(
                map_path;
                workers = ["parent"],
                project = tmp,
                gb_per_worker = 2.0,
            )
        end
        @test sized.ok
        @test sized.suggest === :ride
        @test sized.slots isa DistSSHRun.WorkerPlan
        local_total, local_nproc = DistSSHRun.get_local_resources()
        @test sized.slots.parent_workers == DistSSHRun.size_worker_count(
            local_total, local_nproc, 2.0; is_parent = true,
        )
        buf2 = IOBuffer()
        DistSSHRun.print_plan(sized; io = buf2)
        @test occursin("slots:", String(take!(buf2)))

        function _plan_write(name, src)
            path = joinpath(tmp, name)
            write(path, src)
            return DistSSHRun.plan(path)
        end
        @test _plan_write("defworkers.jl", "workers() = 4\n").suggest === :go
        @test _plan_write("fnworkers.jl", "function workers()\n    4\nend\n").suggest === :go
        @test _plan_write("foopmap.jl", "Foo.pmap(identity, 1:2)\n").suggest === :go
        @test _plan_write("itmap.jl", "Iterators.map(identity, 1:2)\n").suggest === :go
        @test _plan_write(
            "thspawn.jl",
            "using Base.Threads: @spawn\n@spawn 1\n",
        ).suggest === :go
        @test _plan_write("map2.jl", "map(f, a, b)\n").suggest === :go
        @test _plan_write("mapdo.jl", "map(xs) do x\n    x\nend\n").suggest === :go
        @test _plan_write("typed.jl", "Int[x for x in 1:3]\n").suggest === :go
        dist_every = _plan_write("devery.jl", "Distributed.@everywhere x = 1\n")
        @test dist_every.suggest === :drive
        @test any(f -> f.status === :drive_vocab, dist_every.findings)
        dist_pmap = _plan_write("dpmap.jl", "Distributed.pmap(identity, 1:2)\n")
        @test dist_pmap.suggest === :drive
        bare_spawn = _plan_write("bspawn.jl", "@spawn 1\n")
        @test bare_spawn.suggest === :drive
        bad = _plan_write("bad.jl", "function foo(\n")
        @test !bad.ok
        @test bad.suggest === :go
        bad_error = bad.error
        @test bad_error !== nothing
        @test occursin("ParseError", bad_error)

        for src in (
                "map(f, 1:8)\n",
                "filter(iseven, 1:10)\n",
                "ys = [x^2 for x in 1:4]\n",
                """
                for i in eachindex(xs)
                    results[i] = xs[i]
                end
                """,
                "map(f, a, b)\n",
                "map(xs) do x\n    x\nend\n",
                "Int[x for x in 1:3]\n",
                "Iterators.map(identity, 1:2)\n",
                "workers() = 4\n",
            )
            ex = Meta.parseall(src)
            _plan_each_subexpr(ex) do node
                kind = DistSSHRun._plan_candidate_kind(node)
                kind === nothing && return
                @test DistSSHRun._ride_rewrite(node) != node
            end
        end
    end
end
