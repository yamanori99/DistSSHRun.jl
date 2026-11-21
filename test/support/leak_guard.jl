if !isdefined(@__MODULE__, :_DISTSSH_TEST_LEAK_TAG)

    using DistSSHRun.DistSSHBase: ProcessRow, processes_with_env, reap!, wait_gone

    const _DISTSSH_TEST_LEAK_TAG = "DISTSSH_TEST_LEAK_TAG"
    const _LEAK_GUARD_GRACE_S = 15.0
    const _LEAK_GUARD_RUN_ID = Ref{String}(
        string("test-", getpid(), "-", rand(UInt32)),
    )
    const _TEST_HARNESS_ENV = Ref{Any}(nothing)

    function _capture_test_harness_env!()
        if _TEST_HARNESS_ENV[] === nothing
            _TEST_HARNESS_ENV[] = (
                load_path = copy(LOAD_PATH),
                julia_lp = get(ENV, "JULIA_LOAD_PATH", nothing),
                active = Base.ACTIVE_PROJECT[],
            )
        end
        return nothing
    end

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

    function _assert_no_leaked_processes(
            tag::AbstractString;
            grace::Real = _LEAK_GUARD_GRACE_S,
            label::AbstractString = "",
            broken::Bool = false,
            broken_rows::Union{Nothing, Function} = nothing,
        )
        key = _DISTSSH_TEST_LEAK_TAG
        list = () -> processes_with_env(key, String(tag))
        rows = wait_gone(list; timeout = grace)
        assert_rows = if broken_rows === nothing
            rows
        else
            filter(broken_rows, rows)
        end
        if !isempty(assert_rows)
            head = isempty(label) ? "leaked processes" : "leaked processes ($label)"
            println(stderr, "──── $head (tag=$(repr(tag))) ────")
            print(stderr, _format_leak_rows(assert_rows))
            println(stderr, "──── end leaked processes ────")
        end
        try
            if broken
                @test_broken isempty(assert_rows)
            else
                @test isempty(rows)
            end
        finally
            to_reap = broken_rows === nothing ? rows : assert_rows
            reap!(to_reap)
            survivors = wait_gone(list; timeout = 3.0)
            if !isempty(survivors)
                reap!(broken_rows === nothing ? survivors : filter(broken_rows, survivors))
                survivors = wait_gone(list; timeout = 0.5)
            end
            if !isempty(survivors)
                println(stderr, "──── leaked processes still running after reap ────")
                print(stderr, _format_leak_rows(survivors))
                println(stderr, "──── end leaked processes still running ────")
            end
        end
        return nothing
    end

    function _restore_test_harness_env!()
        snap = _TEST_HARNESS_ENV[]
        snap === nothing && return nothing
        try
            empty!(LOAD_PATH)
            append!(LOAD_PATH, snap.load_path)
        catch
        end
        try
            if snap.julia_lp === nothing
                delete!(ENV, "JULIA_LOAD_PATH")
            else
                ENV["JULIA_LOAD_PATH"] = snap.julia_lp
            end
        catch
        end
        try
            Base.ACTIVE_PROJECT[] = snap.active
        catch
        end
        return nothing
    end

    function _with_test_load_path_guard(f::Function)
        _capture_test_harness_env!()
        try
            return f()
        finally
            _restore_test_harness_env!()
        end
    end

    function _with_leak_guard(f::Function, rel::AbstractString)
        tag = _leak_guard_tag(rel)
        return _with_test_load_path_guard() do
            return withenv(_DISTSSH_TEST_LEAK_TAG => tag) do
                try
                    return f()
                finally
                    _assert_no_leaked_processes(tag; label = rel)
                end
            end
        end
    end

end
