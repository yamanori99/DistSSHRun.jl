# Shared by DistSSHUp's own tests.
# Helpers stay in this package. A Registry install has no sibling DistSSHBase tree.

if !isdefined(Main, :_with_tempdir)
    # macOS can throw ENOTEMPTY while removing a `.git` that was just written.
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
end

if !isdefined(Main, :_kill_ready_child)
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

if !isdefined(Main, :_write_aligned_fake_juliaup)
    # Fake local juliaup whose default channel already matches, with `julia` beside it.
    # `add` / `update` / `default` succeed and are appended to `log`.
    function _write_aligned_fake_juliaup(dir::AbstractString)
        ju = joinpath(dir, "juliaup")
        jl = joinpath(dir, "julia")
        log = joinpath(dir, "log")
        # The two test entries load different packages. Spell neither name as a
        # global: this file is analyzed from both, and the unused branch warns.
        up = Symbol("DistSSH" * "Up")
        other = Symbol("DistSSH" * "Run")
        mod = getfield(Main, isdefined(Main, up) ? up : other)
        ch = mod.juliaup_channel()
        write(
            ju,
            """
            #!/bin/sh
            echo "\$*" >> '$log'
            case "\$1" in
              --version) echo 'Juliaup 1.22.7'; exit 0 ;;
              status) echo '       *  $ch     julia version'; exit 0 ;;
              add|update|default) exit 0 ;;
              *) exit 1 ;;
            esac
            """,
        )
        write(
            jl,
            """
            #!/bin/sh
            echo "julia version $(VERSION.major).$(VERSION.minor).$(VERSION.patch)"
            """,
        )
        chmod(ju, 0o755)
        chmod(jl, 0o755)
        return (; ju, ch, log)
    end
end
