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

    function _leak_guard_argv_has_token(cmd::AbstractString, token::AbstractString)::Bool
        return any(part -> part == token, split(cmd))
    end

    function _leak_guard_julia_parent(pid::Int)::Bool
        pid == getpid() && return true
        proc = "/proc/$pid/cmdline"
        isfile(proc) || return false
        raw = read(proc)
        return occursin("julia", lowercase(String(raw)))
    end

    function _leak_guard_orphan_reparented(row::ProcessRow)::Bool
        row.ppid == getpid() && return false
        _leak_guard_julia_parent(row.ppid) && return false
        return true
    end

    function _leak_guard_known_precompile_orphan(row::ProcessRow)::Bool
        _leak_guard_orphan_reparented(row) || return false
        return _leak_guard_argv_has_token(row.command, "--output-incremental") ||
            _leak_guard_argv_has_token(row.command, "--output-incremental=yes") ||
            _leak_guard_argv_has_token(row.command, "--output-o")
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
        rec = DistSSHRun.active_deploy_record()
        return (
            env = env,
            load = copy(LOAD_PATH),
            proj = Base.active_project(),
            deploy = rec === nothing ? nothing : deepcopy(rec),
            selection = DistSSHRun.active_source_selection(),
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
        if after.deploy !== nothing
            push!(msgs, "active_deploy_record left=$(repr(after.deploy))")
        end
        if after.selection !== nothing
            push!(msgs, "active_source_selection left=$(repr(after.selection))")
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
        rows = filter(row -> !_leak_guard_known_precompile_orphan(row), rows)
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
            # Isolate the next file on a reused parallel worker.
            DistSSHRun._clear_active_deploy_record!()
            DistSSHRun._clear_active_selection!()
            _assert_no_leaked_processes(tag; label = rel)
        end
    end

end
