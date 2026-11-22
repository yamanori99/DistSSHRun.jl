if !isdefined(@__MODULE__, :_DISTSSH_TEST_LEAK_TAG)

    using DistSSHRun.DistSSHBase: ProcessRow, processes_with_env, wait_gone

    const _DISTSSH_TEST_LEAK_TAG = "DISTSSH_TEST_LEAK_TAG"
    const _LEAK_GUARD_GRACE_S = 15.0
    const _LEAK_GUARD_RUN_ID = Ref{String}(
        string("test-", getpid(), "-", rand(UInt32)),
    )

    function _leak_guard_tag(rel::AbstractString)::String
        rel = replace(String(rel), '\\' => '/')
        return string(_LEAK_GUARD_RUN_ID[], ":", rel)
    end

    function _leak_guard_known_worker_orphan(row::ProcessRow)::Bool
        return row.ppid == 1 && occursin("--worker", row.command)
    end

    function _format_leak_rows(rows::AbstractVector{ProcessRow})::String
        io = IOBuffer()
        for row in rows
            println(
                io,
                "  pid=$(row.pid) ppid=$(row.ppid) etime=$(row.etime) $(row.command)",
            )
        end
        return String(take!(io))
    end

    function _leak_guard_capture()
        env = Dict{String, String}()
        for (k, v) in ENV
            env[String(k)] = String(v)
        end
        return (
            env = env,
            load = copy(LOAD_PATH),
            proj = Base.active_project(),
        )
    end

    function _leak_guard_state_messages(before, after)::Vector{String}
        msgs = String[]
        ks = union(Base.keys(before.env), Base.keys(after.env))
        for k in sort!(collect(ks))
            k == _DISTSSH_TEST_LEAK_TAG && continue
            b = get(before.env, k, nothing)
            a = get(after.env, k, nothing)
            b == a && continue
            push!(msgs, "ENV[$(k)] before=$(repr(b)) after=$(repr(a))")
        end
        if before.load != after.load
            push!(msgs, "LOAD_PATH before=$(repr(before.load)) after=$(repr(after.load))")
        end
        if before.proj != after.proj
            push!(msgs, "active_project before=$(repr(before.proj)) after=$(repr(after.proj))")
        end
        return msgs
    end

    function _assert_no_leaked_processes(
            tag::AbstractString;
            grace::Real = _LEAK_GUARD_GRACE_S,
            label::AbstractString = "",
        )
        key = _DISTSSH_TEST_LEAK_TAG
        list = () -> processes_with_env(key, String(tag))
        rows = wait_gone(list; timeout = grace)
        if !isempty(rows)
            head = isempty(label) ? "leaked processes" : "leaked processes ($label)"
            println(stderr, "──── $head (tag=$(repr(tag))) ────")
            print(stderr, _format_leak_rows(rows))
            println(stderr, "──── end leaked processes ────")
        end
        @test isempty(rows)
        return nothing
    end

    function _with_leak_guard(f::Function, rel::AbstractString)
        tag = _leak_guard_tag(rel)
        before = _leak_guard_capture()
        ENV[_DISTSSH_TEST_LEAK_TAG] = tag
        try
            return f()
        finally
            msgs = _leak_guard_state_messages(before, _leak_guard_capture())
            for msg in msgs
                println(stderr, "leak: $(rel): $(msg)")
            end
            @test isempty(msgs)
            _assert_no_leaked_processes(tag; label = rel)
        end
    end

end
