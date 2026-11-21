# Shared test helpers for DistSSHBase and DistSSHUp (single Main definitions for JETLS).

if !isdefined(@__MODULE__, :_with_tempdir)
    function _rm_tempdir!(path::AbstractString)
        pauses = (0.05, 0.2, 0.5)
        for pause in pauses
            try
                rm(path; recursive = true, force = true)
                return nothing
            catch e
                if !(e isa Base.IOError && e.code == Base.UV_ENOTEMPTY)
                    rethrow()
                end
                sleep(pause)
            end
        end
        rm(path; recursive = true, force = true)
        return nothing
    end

    function _with_tempdir(f::Function)
        path = abspath(string(mktempdir()))
        try
            return f(path)
        finally
            _rm_tempdir!(path)
        end
    end

    function _kill_ready_child(ready::AbstractString; signal::Integer = Base.SIGTERM)
        t0 = time()
        pid = nothing
        while time() - t0 < 20
            if isfile(ready)
                pid = tryparse(Int, strip(read(ready, String)))
                pid === nothing || break
            end
            sleep(0.02)
        end
        pid === nothing && error("timed out waiting for $(ready)")
        ccall(:kill, Cint, (Cint, Cint), Cint(pid), Cint(signal)) == 0 ||
            error("kill $(pid) failed")
        return pid
    end
end
