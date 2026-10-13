# Shared by DistSSHUp's own tests and DistSSHRun's suite.

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
