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

if !isdefined(Main, :_write_aligned_fake_juliaup)
    # Fake local juliaup already on this process's channel, with `julia` beside it.
    function _write_aligned_fake_juliaup(dir::AbstractString)
        ju = joinpath(dir, "juliaup")
        jl = joinpath(dir, "julia")
        ch = "$(VERSION.major).$(VERSION.minor)"
        write(
            ju,
            """
            #!/bin/sh
            case "\$1" in
              --version) echo 'Juliaup 1.22.7'; exit 0 ;;
              status) echo '       *  $ch     julia version'; exit 0 ;;
              add|update|default) echo "unexpected \$1" >&2; exit 1 ;;
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
        return (; ju, ch)
    end
end
