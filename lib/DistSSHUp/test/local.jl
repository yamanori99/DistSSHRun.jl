using Test

@testset "local juliaup" begin
    mktempdir() do d
        ju = joinpath(d, "juliaup")
        jl = joinpath(d, "julia")
        write(
            ju, """
            #!/bin/sh
            case "\$1" in
              --version) echo 'Juliaup 1.22.7'; exit 0 ;;
              add|update|default)
                echo "Checking for new Julia versions" >&2
                echo "'1.13' is already installed."
                exit 0
                ;;
              status) echo "1.12"; exit 0 ;;
              *) exit 1 ;;
            esac
            """
        )
        write(
            jl, """
            #!/bin/sh
            echo "julia version $(VERSION.major).$(VERSION.minor).$(VERSION.patch)"
            """
        )
        chmod(ju, 0o755)
        chmod(jl, 0o755)
        withenv("DISTSSH_TEST" => "1", "DISTSSH_TEST_LOCAL_JULIAUP" => ju) do
            @test DistSSHBase.find_local_juliaup() == ju
            ch = "$(VERSION.major).$(VERSION.minor)"
            holder = Ref{Any}()
            captured = mktemp() do path, io
                redirect_stdout(io) do
                    redirect_stderr(io) do
                        holder[] = DistSSHUp.juliaup_align_local!(ch)
                    end
                end
                flush(io)
                return read(path, String)
            end
            r = holder[]
            @test r.changed
            @test DistSSHUp.julia_version_mismatch_kind(VERSION, r.ver) != :minor
            @test !occursin("Checking for new Julia versions", captured)
        end
    end

    mktempdir() do d
        ju = joinpath(d, "juliaup")
        jl = joinpath(d, "julia")
        log = joinpath(d, "log")
        ch = "$(VERSION.major).$(VERSION.minor)"
        write(
            ju,
            """
            #!/bin/sh
            case "\$1" in
              --version) echo 'Juliaup 1.22.7'; exit 0 ;;
              status) echo '       *  $ch     julia version'; exit 0 ;;
              add|update|default) echo "\$*" >> '$log'; exit 0 ;;
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
        withenv("DISTSSH_TEST" => "1", "DISTSSH_TEST_LOCAL_JULIAUP" => ju) do
            r = DistSSHUp.juliaup_align_local!(ch)
            @test r.changed
            @test DistSSHUp.julia_version_mismatch_kind(VERSION, r.ver) != :minor
            logged = read(log, String)
            @test count(==("update $ch"), split(logged, '\n'; keepempty = false)) == 1
        end
    end

    mktempdir() do d
        ju = joinpath(d, "juliaup")
        jl = joinpath(d, "julia")
        write(
            ju, """
            #!/bin/sh
            case "\$1" in
              --version) echo 'Juliaup 1.22.7'; exit 0 ;;
              add) echo "network failed"; exit 1 ;;
              status) echo "empty"; exit 0 ;;
              *) exit 1 ;;
            esac
            """
        )
        write(
            jl, """
            #!/bin/sh
            echo "julia version $(VERSION.major).$(VERSION.minor).$(VERSION.patch)"
            """
        )
        chmod(ju, 0o755)
        chmod(jl, 0o755)
        withenv("DISTSSH_TEST" => "1", "DISTSSH_TEST_LOCAL_JULIAUP" => ju) do
            err = try
                DistSSHUp.juliaup_align_local!("$(VERSION.major).$(VERSION.minor)")
                nothing
            catch e
                sprint(showerror, e)
            end
            @test err !== nothing
            @test occursin("network failed", err)
        end
    end

    mktempdir() do d
        ju = joinpath(d, "juliaup")
        write(
            ju,
            """
            #!/bin/sh
            echo 'Juliaup 1.21.0'
            """,
        )
        chmod(ju, 0o755)
        withenv("DISTSSH_TEST" => "1", "DISTSSH_TEST_LOCAL_JULIAUP" => ju) do
            err = try
                DistSSHUp.juliaup_update_local!()
                ""
            catch e
                e isa ErrorException ? e.msg : sprint(showerror, e)
            end
            @test occursin("1.21.0", err)
            @test occursin("older than 1.22", err)
        end
    end

    mktempdir() do d
        ju = joinpath(d, "juliaup")
        ready = joinpath(d, "ready")
        write(
            ju,
            """
            #!/bin/sh
            echo '     *  1.13     1.13.2+0.aarch64'
            echo \$\$ > '$ready'
            exec sleep 30
            """,
        )
        chmod(ju, 0o755)
        withenv("DISTSSH_TEST" => "1", "DISTSSH_TEST_LOCAL_JULIAUP" => ju) do
            task = @async DistSSHUp.juliaup_default_patch("parent")
            _kill_ready_child(ready; signal = Base.SIGTERM)
            @test fetch(task) == "-"
        end
        write(
            ju,
            """
            #!/bin/sh
            echo '     *  1.13     1.13.2+0.aarch64'
            exit 3
            """,
        )
        chmod(ju, 0o755)
        withenv("DISTSSH_TEST" => "1", "DISTSSH_TEST_LOCAL_JULIAUP" => ju) do
            @test DistSSHUp.juliaup_default_patch("parent") == "-"
        end
    end
end
