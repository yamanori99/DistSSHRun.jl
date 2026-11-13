using Test
using Distributed

@testset "ride" begin
    @testset "activate project" begin
        prev = Base.active_project()
        _with_tempdir() do tmp
            write(
                joinpath(tmp, "Project.toml"),
                """
                name = "RideAct"
                uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                version = "0.1.0"
                """,
            )
            try
                DistSSHRun._ride_activate_project!(tmp)
                active = Base.active_project()
                @test active !== nothing
                @test startswith(active, tmp)
            finally
                DistSSHRun._ride_restore_project!(prev)
            end
        end
        @test Base.active_project() == prev
    end

    @testset "rewrite" begin
        ex = Meta.parse("map(f, xs)")
        rw = DistSSHRun._ride_rewrite(ex)
        @test rw.head === :call
        @test rw.args[1] === GlobalRef(DistSSHRun, :_ride_map)
        @test rw.args[2].head === :call
        @test rw.args[2].args[1] === GlobalRef(DistSSHRun, :_ride_named_fn)

        fx = Meta.parse("filter(iseven, xs)")
        @test DistSSHRun._ride_rewrite(fx).args[1] === GlobalRef(DistSSHRun, :_ride_filter)

        mx2 = Meta.parse("map(+, xs, ys)")
        @test DistSSHRun._ride_rewrite(mx2).args[1] === :map

        itmap = Meta.parse("Iterators.map(identity, xs)")
        @test DistSSHRun._ride_rewrite(itmap).args[1] isa Expr

        cx = Meta.parse("[x^2 for x in xs]")
        cr = DistSSHRun._ride_rewrite(cx)
        @test cr.args[1] === GlobalRef(DistSSHRun, :_ride_map)

        fx2 = Meta.parse("for i in xs; f(i); end")
        @test DistSSHRun._ride_rewrite(fx2).head === :for

        fill = Meta.parse("for i in eachindex(xs); ys[i] = xs[i] * xs[i]; end")
        fr = DistSSHRun._ride_rewrite(fill)
        @test fr.head === :call
        @test fr.args[1] === GlobalRef(DistSSHRun, :_ride_index_fill!)
        @test !(
            fr.args[4] isa Expr && fr.args[4].head === :call &&
                fr.args[4].args[1] === :collect
        )
        ys = zeros(Int, 3)
        @test DistSSHRun._ride_index_fill!(ys, i -> i * i, 1:3) === nothing
        @test ys == [1, 4, 9]

        acc = Meta.parse("for x in xs; s += x; end")
        @test DistSSHRun._ride_rewrite(acc).head === :for

        stencil = Meta.parse("for i in 2:length(dest); dest[i] = alias[i - 1]; end")
        @test DistSSHRun._ride_rewrite(stencil).head === :for

        pre = DistSSHRun._ride_worker_prelude(
            Meta.parseall(
                """
                function work(x)
                    x + 1
                end
                ys = map(work, 1:3)
                """
            )
        )
        s = string(pre)
        @test occursin("work", s)
        @test !occursin("map", s)

        plan = DistSSHRun._ride_resolve_plan(["child:h:2", "parent:1"])
        @test plan.parent_workers == 1
        @test plan.child_workers["h"] == 2

        _with_tempdir() do tmp
            script = joinpath(tmp, "map.jl")
            d1 = DistSSHRun._ride_batch_dir(script, nothing; project = tmp)
            d2 = DistSSHRun._ride_batch_dir(script, nothing; project = tmp)
            @test isdir(d1) && isdir(d2)
            @test d1 != d2
        end
    end

    @testset "kit_run_result" begin
        r = DistSSHRun.RideResult(true, "s.jl", 2, true, nothing, "1.13")
        @test DistSSHRun.result_run_dir(r) === nothing
        kr = DistSSHRun.kit_run_result(r)
        @test kr.ok
        @test kr.kind === :ride
        @test kr.exit_code == 0
        @test kr.failed_step === nothing
        bad = DistSSHRun.RideResult(false, "s.jl", 0, nothing, "boom", "1.13")
        @test DistSSHRun.kit_run_result(bad).failed_step == "ride"
    end

    @testset "script scan" begin
        _with_tempdir() do tmp
            function _scan(name, src)
                path = joinpath(tmp, name)
                write(path, src)
                return DistSSHRun._script_scan(path)
            end
            @test _scan("defworkers.jl", "workers() = 4\n").drive_line === nothing
            @test _scan("fnworkers.jl", "function workers()\n    4\nend\n").drive_line === nothing
            @test _scan("foopmap.jl", "Foo.pmap(identity, 1:2)\n").drive_line === nothing
            @test _scan("itmap.jl", "Iterators.map(identity, 1:2)\n").drive_line === nothing
            @test _scan(
                "thspawn.jl",
                "using Base.Threads: @spawn\n@spawn 1\n",
            ).drive_line === nothing
            @test _scan("map2.jl", "map(f, a, b)\n").drive_line === nothing
            dist_every = _scan("devery.jl", "Distributed.@everywhere x = 1\n")
            @test dist_every.error === nothing
            @test dist_every.drive_line !== nothing
            dist_pmap = _scan("dpmap.jl", "Distributed.pmap(identity, 1:2)\n")
            @test dist_pmap.drive_line !== nothing
            bare_spawn = _scan("bspawn.jl", "@spawn 1\n")
            @test bare_spawn.drive_line !== nothing
            missing = DistSSHRun._script_scan(joinpath(tmp, "nope.jl"))
            missing_error = missing.error
            @test missing_error isa String
            @test occursin("file not found", missing_error::String)
            bad = _scan("bad.jl", "function foo(\n")
            bad_error = bad.error
            @test bad_error isa String
            @test occursin("ParseError", bad_error::String)
        end
    end

    _with_tempdir() do tmp
        _write_host_project!(tmp, "RideHost")
        function ride_local(args...; kwargs...)
            return DistSSHRun.ride!(args...; project = tmp, kwargs...)
        end
        out = joinpath(tmp, "out.txt")
        map_path = joinpath(tmp, "mapped.jl")
        write(
            map_path, """
            ys = map(x -> x + 1, 1:4)
            write($(repr(out)), join(string.(ys), ","))
            """
        )
        r = ride_local(map_path, "parent:1"; spi_check = true)
        @test r.ok
        @test r.workers == 1
        @test r.spi_ok === true
        @test read(out, String) == "2,3,4,5"
        @test r.output_dir !== nothing
        @test r.run_dir !== nothing
        @test r.run_dir != r.output_dir
        withenv(DistSSHRun.DISTSSH_RUN_DIR_ENV => nothing) do
            @test DistSSHRun.result_run_dir(r) == r.run_dir
            @test DistSSHRun.kit_run_result(r).run_dir == r.run_dir
        end
        @test !isfile(joinpath(something(r.output_dir, ""), "kit.hosts"))
        st = DistSSHRun.drive_host_status(something(r.output_dir, ""))
        @test any(row -> row.host == DistSSHRun.PARENT_HOST_NAME, st)

        _with_tempdir() do hosts_tmp
            DistSSHRun._write_kit_hosts_file(["alice@h1", "bob@h2"], hosts_tmp, nothing)
            @test DistSSHRun._read_kit_hosts(hosts_tmp) == ["alice@h1", "bob@h2"]
        end

        buf = IOBuffer()
        DistSSHRun.print_ride(r; io = buf)
        shown = String(take!(buf))
        @test startswith(shown, "DistSSHKit ride\n")
        @test occursin("Script: ", shown)
        @test occursin("Workers: ", shown)
        @test occursin("Julia: ", shown)
        @test occursin("DistSSHRun: ", shown)
        @test occursin("SPI check: passed", shown)
        @test !occursin("Ride:", shown)

        # One `ride!` above is the ordinary parent:1 map path. The rest repeat
        # worker startup (filter, pmap, SPI variants).
        if _distsshrun_test_short()
            @test_skip "DISTSSHRUN_TEST_SHORT: extra ride! cases (filter, pmap, SPI variants)"
        else
            fout = joinpath(tmp, "filt.txt")
            filt = joinpath(tmp, "filt.jl")
            write(
                filt, """
                ys = filter(iseven, 1:6)
                write($(repr(fout)), join(string.(ys), ","))
                """
            )
            rf = ride_local(filt, "parent:1"; spi_check = true)
            @test rf.ok
            @test read(fout, String) == "2,4,6"

            named = joinpath(tmp, "named.jl")
            nout = joinpath(tmp, "named.txt")
            write(
                named, """
                function work(x)
                    x * x
                end
                ys = map(work, 1:3)
                write($(repr(nout)), join(string.(ys), ","))
                """
            )
            rn = ride_local(named, "parent:1"; spi_check = true)
            @test rn.ok
            @test read(nout, String) == "1,4,9"

            loop = joinpath(tmp, "loop.jl")
            lout = joinpath(tmp, "loop.txt")
            write(
                loop, """
                xs = 1:4
                ys = similar(collect(xs))
                for i in eachindex(xs)
                    ys[i] = xs[i] * xs[i]
                end
                write($(repr(lout)), join(string.(ys), ","))
                """
            )
            rl = ride_local(loop, "parent:1"; spi_check = true)
            @test rl.ok
            @test rl.spi_ok !== false
            @test read(lout, String) == "1,4,9,16"

            val_path = joinpath(tmp, "forval.jl")
            vout = joinpath(tmp, "forval.txt")
            write(
                val_path, """
                ys = zeros(Int, 3)
                x = (for i in eachindex(ys)
                    ys[i] = i * i
                end)
                write($(repr(vout)), string(x === nothing) * ";" * join(string.(ys), ","))
                """
            )
            rv = ride_local(val_path, "parent:1"; spi_check = true)
            @test rv.ok
            @test read(vout, String) == "true;1,4,9"

            st_path = joinpath(tmp, "stateful.jl")
            stout = joinpath(tmp, "stateful.txt")
            write(
                st_path, """
                xs = [1, 2, 3, 4]
                ys = similar(xs)
                for i in Iterators.Stateful(eachindex(xs))
                    ys[i] = xs[i] * xs[i]
                end
                write($(repr(stout)), join(string.(ys), ","))
                """
            )
            rs = ride_local(st_path, "parent:1"; spi_check = false)
            @test rs.ok
            @test read(stout, String) == "1,4,9,16"

            alias_path = joinpath(tmp, "alias.jl")
            aout = joinpath(tmp, "alias.txt")
            write(
                alias_path, """
                dest = [1, 2, 3]
                alias = dest
                for i in 2:length(dest)
                    dest[i] = alias[i - 1]
                end
                write($(repr(aout)), join(string.(dest), ","))
                """
            )
            ra = ride_local(alias_path, "parent:1"; spi_check = false)
            @test ra.ok
            @test read(aout, String) == "1,1,1"

            obs_path = joinpath(tmp, "observe.jl")
            oout = joinpath(tmp, "observe.txt")
            write(
                obs_path, """
                dest = [1, 2, 3]
                seen = Int[]
                observe(i) = (push!(seen, dest[1]); 0)
                for i in eachindex(dest)
                    dest[i] = observe(i)
                end
                write($(repr(oout)), join(string.(seen), ",") * ";" * join(string.(dest), ","))
                """
            )
            ro = ride_local(obs_path, "parent:1"; spi_check = false)
            @test ro.ok
            @test read(oout, String) == "1,0,0;0,0,0"

            gen_path = joinpath(tmp, "geniter.jl")
            gout = joinpath(tmp, "geniter.txt")
            write(
                gen_path, """
                dest = zeros(Int, 3)
                n = Ref(0)
                struct _RideUnknownIter
                    n::Ref{Int}
                end
                Base.IteratorSize(::Type{_RideUnknownIter}) = Base.SizeUnknown()
                function Base.iterate(it::_RideUnknownIter, st=1)
                    st > 3 && return nothing
                    it.n[] += 1
                    return (st, st + 1)
                end
                for i in _RideUnknownIter(n)
                    dest[i] = n[]
                end
                write($(repr(gout)), join(string.(dest), ","))
                """
            )
            rg = ride_local(gen_path, "parent:1"; spi_check = false)
            @test rg.ok
            @test read(gout, String) == "1,2,3"

            haslen_path = joinpath(tmp, "hasleniter.jl")
            hout = joinpath(tmp, "hasleniter.txt")
            write(
                haslen_path, """
                dest = zeros(Int, 3)
                n = Ref(0)
                struct _RideHasLenIter
                    n::Ref{Int}
                end
                Base.IteratorSize(::Type{_RideHasLenIter}) = Base.HasLength()
                Base.length(::_RideHasLenIter) = 3
                function Base.iterate(it::_RideHasLenIter, st=1)
                    st > 3 && return nothing
                    it.n[] += 1
                    return (st, st + 1)
                end
                for i in _RideHasLenIter(n)
                    dest[i] = n[]
                end
                write($(repr(hout)), join(string.(dest), ","))
                """
            )
            rh = ride_local(haslen_path, "parent:1"; spi_check = false)
            @test rh.ok
            @test read(hout, String) == "1,2,3"

            pmapnest_path = joinpath(tmp, "pmapnest.jl")
            pout = joinpath(tmp, "pmapnest.txt")
            write(
                pmapnest_path, """
                function inner_overlap()
                    data = [1, 2, 3, 4]
                    dest = @view data[2:4]
                    src = @view data[1:3]
                    for i in eachindex(dest)
                        dest[i] = src[i]
                    end
                    return join(string.(dest), ",")
                end
                out = Vector{String}(undef, 4)
                for i in eachindex(out)
                    out[i] = inner_overlap()
                end
                write($(repr(pout)), join(out, ";"))
                """
            )
            rp = ride_local(pmapnest_path, "parent:2"; spi_check = false)
            @test rp.ok
            @test read(pout, String) == "1,1,1;1,1,1;1,1,1;1,1,1"

            overlap_src = """
            data = [1, 2, 3, 4]
            dest = @view data[2:4]
            src = @view data[1:3]
            for i in eachindex(dest)
                dest[i] = src[i]
            end
            write(ARGS[1], join(string.(dest), ","))
            """
            holder_src(struct_name) = """
            struct $(struct_name)
                src::AbstractArray
            end
            data = [1, 2, 3, 4]
            dest = @view data[2:4]
            holder = $(struct_name)(@view data[1:3])
            for i in eachindex(dest)
                dest[i] = holder.src[i]
            end
            write(ARGS[1], join(string.(dest), ","))
            """
            nest_n = DistSSHRun._RIDE_CAPTURE_DEPTH + 3
            nested_src(struct_name) = begin
                nest_wraps = join(
                    ["w = $(struct_name)(w)" for _ in 1:(nest_n - 1)],
                    "\n            ",
                )
                nest_get = "w" * repeat(".inner", nest_n)
                """
                struct $(struct_name)
                    inner
                end
                data = [1, 2, 3, 4]
                dest = @view data[2:4]
                w = $(struct_name)(@view data[1:3])
                $(nest_wraps)
                for i in eachindex(dest)
                    dest[i] = $(nest_get)[i]
                end
                write(ARGS[1], join(string.(dest), ","))
                """
            end
            const_nospi_src = """
            const _RideConstData_nospi = [1, 2, 3, 4]
            dest = @view _RideConstData_nospi[2:4]
            const _RideConstSrc_nospi = @view _RideConstData_nospi[1:3]
            for i in eachindex(dest)
                dest[i] = Main._RideConstSrc_nospi[i]
            end
            write(ARGS[1], join(string.(dest), ","))
            """
            const_spi_src = """
            const _RideConstData_spi = [1, 2, 3, 4]
            dest = @view _RideConstData_spi[2:4]
            const _RideConstSrc_spi = @view _RideConstData_spi[1:3]
            for i in eachindex(dest)
                dest[i] = Main._RideConstSrc_spi[i]
            end
            write(ARGS[1], join(string.(dest), ","))
            """
            for (body, spi, stem) in (
                    (overlap_src, false, "overlap_nospi"),
                    (overlap_src, true, "overlap_spi"),
                    (holder_src("_RideViewHolder_nospi"), false, "holder_nospi"),
                    (holder_src("_RideViewHolder_spi"), true, "holder_spi"),
                    (nested_src("_RideNest_nospi"), false, "nested_nospi"),
                    (nested_src("_RideNest_spi"), true, "nested_spi"),
                    (const_nospi_src, false, "const_nospi"),
                    (const_spi_src, true, "const_spi"),
                )
                opath = joinpath(tmp, stem * ".jl")
                oout = joinpath(tmp, stem * ".txt")
                write(opath, replace(body, "ARGS[1]" => repr(oout)))
                rr = ride_local(opath, "parent:1"; spi_check = spi)
                @test rr.ok
                @test read(oout, String) == "1,1,1"
            end

            child = ride_local(map_path, "child:host1")
            @test !child.ok
            @test occursin(":N", something(child.error, ""))

            drive_path = joinpath(tmp, "driver.jl")
            write(drive_path, "using Distributed\npmap(x -> x, 1:2)\n")
            rd = ride_local(drive_path)
            @test !rd.ok
            @test occursin("drive", something(rd.error, ""))
            @test occursin("pmap", something(rd.error, ""))
        end
    end

    @testset "non-empty output directory" begin
        _with_tempdir() do tmp
            _write_host_project!(tmp, "RideOut")
            script = joinpath(tmp, "job.jl")
            write(script, "println(\"hi\")\n")
            dirty = joinpath(tmp, "out")
            mkdir(dirty)
            write(joinpath(dirty, "old.txt"), "old\n")
            err = try
                DistSSHRun.ride!(
                    script;
                    output_dir = dirty,
                    project = tmp,
                    hint_surface = :cli,
                )
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            err isa ArgumentError || error("expected ArgumentError")
            @test occursin("old.txt", err.msg)
            @test occursin("Run `julia -m DistSSHKit help ride` for flags.", err.msg)
            @test !occursin("--help", err.msg)
            @test !isfile(joinpath(dirty, ".kit.lock"))
            @test !isfile(joinpath(dirty, "kit.pid"))
        end
    end

    @testset "ride does not record an earlier ship" begin
        previous = DistSSHRun.active_source_selection()
        function seed_earlier_ship!()
            DistSSHRun._set_active_selection!(
                DistSSHRun.SourceSelection(
                    :ship,
                    "20260101T000000Z-abcdef",
                    "/home/distsshkit/app",
                    "/home/distsshkit/app/runs/20260101T000000Z-abcdef/src",
                    "deadbeef",
                    ["host.test"],
                ),
            )
            return nothing
        end
        function assert_no_shipped(result)
            rd = result.run_dir
            @test rd isa AbstractString
            raw = DistSSHRun.read_kit_run_toml(rd)
            @test raw isa AbstractDict
            prov = raw["provenance"]
            @test prov isa AbstractDict
            @test !haskey(prov, "selection")
            return nothing
        end
        try
            _with_tempdir() do tmp
                _write_host_project!(tmp, "RideProv")
                script = joinpath(tmp, "job.jl")
                write(script, "println(\"ok\")\n")
                bad = joinpath(tmp, "bad.jl")
                write(bad, "error(\"boom\")\n")
                seed_earlier_ship!()
                ok = redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        DistSSHRun.ride!(script; project = tmp)
                    end
                end
                @test ok.ok
                assert_no_shipped(ok)
                seed_earlier_ship!()
                failed = redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        DistSSHRun.ride!(bad; project = tmp)
                    end
                end
                @test !failed.ok
                assert_no_shipped(failed)
            end
        finally
            if previous === nothing
                DistSSHRun._clear_last_ship!()
            else
                DistSSHRun._set_active_selection!(previous)
            end
        end
    end

    @testset "ride retargets SSH project to completed snapshot src" begin
        double = abspath(joinpath(@__DIR__, "..", "..", "fixtures", "fake_ride_work_root_ssh.jl"))
        previous = DistSSHRun.active_source_selection()
        old_remote = get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", nothing)
        function restore_remote!()
            if old_remote === nothing
                delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
            else
                ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = old_remote
            end
            return nothing
        end
        try
            _with_tempdir() do tmp
                local_proj = joinpath(tmp, "local")
                mkpath(local_proj)
                write(joinpath(local_proj, "Project.toml"), "name = \"RideRoot\"\n")
                write(joinpath(local_proj, "Manifest.toml"), "manifest_format = \"2.0\"\n")
                DistSSHRun.clear_last_ship_record!(local_proj)
                script = joinpath(local_proj, "job.jl")
                write(script, "nothing\n")
                remote = joinpath(tmp, "remote")
                snap_id = "20200102T000000Z-bbbbbb"
                older = joinpath(remote, "runs", "20200101T000000Z-aaaaaa", "src")
                newer = joinpath(remote, "runs", snap_id, "src")
                mkpath(older)
                mkpath(newer)
                write(joinpath(older, "Project.toml"), "name = \"Old\"\n")
                write(joinpath(newer, "Project.toml"), "name = \"New\"\n")
                write(joinpath(newer, "Manifest.toml"), "manifest_format = \"2.0\"\n")
                write(
                    joinpath(remote, "runs", snap_id, "run.toml"),
                    DistSSHRun._ship_run_leaf_complete_toml(
                        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    ),
                )
                logp = joinpath(tmp, "ssh.log")
                bindir = joinpath(tmp, "bin")
                mkpath(bindir)
                ssh_bin = joinpath(bindir, "ssh")
                # Version check uses `ssh`, not the test double. Answer that, fail the rest.
                write(
                    ssh_bin,
                    """
                    #!/bin/sh
                    for a in "\$@"; do
                      case "\$a" in
                        *--version*)
                          printf '%s\\n' "julia version 1.13.3"
                          exit 0
                          ;;
                      esac
                    done
                    exit 255
                    """,
                )
                chmod(ssh_bin, 0o755)
                fake = Dict(
                    "DISTSSH_TEST" => "1",
                    "DISTSSH_TEST_SSH" => double,
                    "DISTSSH_TEST_SSH_LOG" => logp,
                    "DISTSSH_TEST_POSIX_SHELL" => "1",
                    "PATH" => bindir * ":" * get(ENV, "PATH", ""),
                )
                host = "ridework.test"
                want = DistSSHRun.canonical_local_path(newer)
                parent_env = joinpath(tmp, "parent-env.txt")
                write(
                    script,
                    """
                    open($(repr(parent_env)), "w") do io
                        println(io, get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", ""))
                    end
                    """,
                )

                withenv(fake...) do
                    ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = remote * "\nbad"
                    DistSSHRun._assign_remote_work_root_env!([host], local_proj)
                    @test ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] == remote * "\nbad"
                    delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
                    DistSSHRun._assign_remote_work_root_env!(String[], local_proj)
                    @test !haskey(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")

                    touch(logp)
                    parent = redirect_stdout(devnull) do
                        redirect_stderr(devnull) do
                            DistSSHRun.ride!(
                                script, ["parent:0"];
                                project = local_proj,
                                remote = remote,
                                output_dir = joinpath(tmp, "parent-out"),
                                spi_check = false,
                            )
                        end
                    end
                    @test parent.ok
                    @test !occursin("__DSR_SNAP_COMPLETE__", read(logp, String))
                    @test strip(read(parent_env, String)) == remote

                    write(script, "nothing\n")
                    rm(logp; force = true)
                    touch(logp)
                    # ride! clears the active selection; pass an explicit snapshot id.
                    child = redirect_stdout(devnull) do
                        redirect_stderr(devnull) do
                            DistSSHRun.ride!(
                                script, ["child:$(host):1"];
                                project = local_proj,
                                remote = remote,
                                run_id = snap_id,
                                julia = "/usr/bin/julia",
                                output_dir = joinpath(tmp, "child-out"),
                                spi_check = false,
                                require_all_hosts = false,
                            )
                        end
                    end
                    logged = read(logp, String)
                    @test child.workers == 0
                    @test child.error isa AbstractString
                    @test occursin("No workers available", something(child.error, ""))
                    @test occursin("__DSR_SNAP_COMPLETE__", logged)
                    @test occursin("--project=" * DistSSHRun.posix_quote(want), logged)
                    @test !occursin("--project=" * DistSSHRun.posix_quote(remote), logged)

                    write(joinpath(remote, "Project.toml"), "name = \"RootWins\"\n")
                    ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = remote
                    DistSSHRun._clear_last_ship!()
                    DistSSHRun.clear_last_ship_record!(local_proj)
                    DistSSHRun._assign_remote_work_root_env!([host], local_proj)
                    @test ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] ==
                        DistSSHRun.canonical_local_path(remote)
                end
            end
        finally
            if previous === nothing
                DistSSHRun._clear_last_ship!()
            else
                DistSSHRun._set_active_selection!(previous)
            end
            restore_remote!()
            delete!(DistSSHRun._PINNED_JULIA, "ridework.test\0/usr/bin/julia")
        end
    end

    @testset "ride map dispatches only to owned workers" begin
        for w in setdiff(workers(), [1])
            rmprocs(w; waitfor = 2.0)
        end
        DistSSHRun._clear_drive_host_worker_ids!()
        empty!(DistSSHRun.RUNNER_WORKER_PROJECT_DIRS)
        addprocs(1; topology = :master_worker)
        foreign = workers()[end]
        before = Set(workers())
        addprocs(1; topology = :master_worker)
        owned = Int[w for w in workers() if w ∉ before]
        DistSSHRun._register_drive_host_worker_ids!(DistSSHRun.PARENT_HOST_NAME, owned)
        DistSSHRun._mark_workers_launched!(owned, pwd())
        try
            probe_src = """
            function ride_probe_pid(x)
                return myid()
            end
            """
            Core.eval(Main, Meta.parseall(probe_src))
            DistSSHRun._ride_load_self_on_workers!()
            DistSSHRun._ride_push_prelude!(Meta.parseall(probe_src))
            out = DistSSHRun._ride_map(:ride_probe_pid, 1:12)
            pids = unique(out)
            @test foreign ∉ pids
            @test all(p -> p == 1 || p in owned, pids)
        finally
            DistSSHRun._clear_drive_host_worker_ids!()
            empty!(DistSSHRun.RUNNER_WORKER_PROJECT_DIRS)
            for w in setdiff(workers(), [1])
                w in workers() && rmprocs(w; waitfor = 2.0)
            end
        end
    end

    @testset "ride map stays on driver when no owned workers" begin
        for w in setdiff(workers(), [1])
            rmprocs(w; waitfor = 2.0)
        end
        DistSSHRun._clear_drive_host_worker_ids!()
        addprocs(1; topology = :master_worker)
        foreign = workers()[end]
        try
            out = DistSSHRun._ride_map(x -> myid(), 1:6)
            @test all(==(1), out)
            @test foreign in workers()
        finally
            for w in setdiff(workers(), [1])
                w in workers() && rmprocs(w; waitfor = 2.0)
            end
        end
    end

    @testset "foreign worker survives ride add error cleanup" begin
        _with_tempdir() do tmp
            script = joinpath(tmp, "noop.jl")
            write(script, "nothing\n")
            addprocs(1; topology = :master_worker)
            foreign = workers()[end]
            task = @async sleep(120)
            DistSSHRun.DRIVE_HOST_STATUS_STOP[] = false
            DistSSHRun.DRIVE_HOST_STATUS_TASK[] = task
            plan = DistSSHRun.WorkerPlan(0, Dict{String, Int}())
            try
                @test_throws ArgumentError DistSSHRun._ride_add_workers!(
                    plan,
                    tmp,
                    script,
                    nothing,
                    false,
                )
                @test foreign in workers()
            finally
                DistSSHRun.DRIVE_HOST_STATUS_STOP[] = true
                DistSSHRun.DRIVE_HOST_STATUS_TASK[] = nothing
                DistSSHRun._clear_drive_host_worker_ids!()
                empty!(DistSSHRun.RUNNER_WORKER_PROJECT_DIRS)
                for w in setdiff(workers(), [1])
                    w in workers() && rmprocs(w; waitfor = 2.0)
                end
            end
        end
    end

    @testset "run_id kw reaches work-root assign" begin
        _with_tempdir() do tmp
            _write_host_project!(tmp, "RideRunId")
            script = joinpath(tmp, "noop.jl")
            write(script, "nothing\n")
            rid = "20260101T000000Z-aaaaaa"
            r = redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    return DistSSHRun.ride!(
                        script, ["parent:1"];
                        project = tmp,
                        run_id = rid,
                    )
                end
            end
            @test r.ok
        end
    end
end
