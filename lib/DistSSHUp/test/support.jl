# Shared by DistSSHUp's own tests.
include(joinpath(@__DIR__, "..", "..", "DistSSHBase", "test", "support.jl"))

if !isdefined(@__MODULE__, :_write_aligned_fake_juliaup)
    function _write_aligned_fake_juliaup(dir::AbstractString)
        ju = joinpath(dir, "juliaup")
        jl = joinpath(dir, "julia")
        log = joinpath(dir, "log")
        up = Symbol("DistSSHUp")
        other = Symbol("DistSSHRun")
        mod = getfield(Main, isdefined(Main, up) ? up : other)
        ch = mod.juliaup_channel()
        base_sym = Symbol("DistSSHBase")
        run_sym = Symbol("DistSSHRun")
        base = if isdefined(Main, base_sym)
            getfield(Main, base_sym)
        else
            getfield(getfield(Main, run_sym), base_sym)
        end
        qlog = base.posix_quote(log)
        write(
            ju,
            """
            #!/bin/sh
            echo "\$*" >> $qlog
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
