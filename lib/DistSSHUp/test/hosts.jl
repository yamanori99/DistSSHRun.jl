@testset "parent and child" begin
    mktempdir() do d
        ju = joinpath(d, "juliaup")
        jl = joinpath(d, "julia")
        ch = "$(VERSION.major).$(VERSION.minor)"
        write(
            ju,
            """
            #!/bin/sh
            case "\$1" in
              --version) echo 'Juliaup 1.22.7'; exit 0 ;;
              status) echo '       *  $ch     julia version'; exit 0 ;;
              update) exit 0 ;;
              add|default) echo "unexpected \$1" >&2; exit 1 ;;
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
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
            r = DistSSHUp.juliaup_align_host!("parent")
            @test r.host == "parent"
            @test r.already
            @test r.channel == ch
            DistSSHUp.juliaup_update_host!("parent")
        end

        ssh = joinpath(d, "ssh.jl")
        write(
            ssh,
            """
            println("already")
            """,
        )
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
            r = DistSSHUp.juliaup_align_host!("host1"; channel = ch)
            @test r.host == "host1"
            @test r.already
            @test r.channel == ch
        end

        write(
            ssh,
            """
            println(stderr, "juliaup not found (tried: juliaup)")
            exit(1)
            """,
        )
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
            @test_throws ErrorException DistSSHUp.juliaup_update_host!("host1")
        end

        write(
            ju,
            """
            #!/bin/sh
            echo '     *  $ch     $ch.2+0.aarch64'
            """,
        )
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
            @test DistSSHUp.juliaup_default_patch("parent") == "$ch.2"
        end
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => joinpath(d, "missing")) do
            @test DistSSHUp.juliaup_default_patch("parent") == "-"
        end

        write(
            ssh,
            """
            println("     *  1.13     1.13.2+0.aarch64.apple.darwin14")
            """,
        )
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
            @test DistSSHUp.juliaup_default_patch("host1") == "1.13.2"
        end
        write(ssh, "exit(1)\n")
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
            @test DistSSHUp.juliaup_default_patch("host1") == "-"
        end
    end
end

@testset "add, default, update, status" begin
    mktempdir() do d
        ju = joinpath(d, "juliaup")
        log = joinpath(d, "log")
        write(
            ju,
            """
            #!/bin/sh
            echo "\$*" >> '$log'
            case "\$1" in
              --version) echo 'Juliaup 1.22.7'; exit 0 ;;
              status)
                echo '     *  1.12     1.12.1+0'
                echo '      1.13     1.13.2+0'
                exit 0
                ;;
              add|update|default) exit 0 ;;
              *) exit 1 ;;
            esac
            """,
        )
        chmod(ju, 0o755)
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
            added = DistSSHUp.juliaup_add_host!("parent", "1.13")
            @test added.host == "parent"
            @test added.channel == "1.13"
            @test !occursin("default", read(log, String))
            rm(log)
            DistSSHUp.juliaup_update_host!("parent"; channel = "1.13")
            update_log = read(log, String)
            @test occursin("update 1.13", update_log)
            @test !occursin("default", update_log)
            DistSSHBase._DETECT_JULIA_PATH_CACHE["parent"] = "/old/julia"
            switched = DistSSHUp.juliaup_default_host!("parent", "1.13")
            @test switched.channel == "1.13"
            @test !haskey(DistSSHBase._DETECT_JULIA_PATH_CACHE, "parent")
            lines = DistSSHUp.juliaup_status_lines("parent"; channel = "1.13")
            @test length(lines) == 1
            @test occursin("1.13.2", lines[1])
        end

        ssh = joinpath(d, "ssh.jl")
        write(
            ssh,
            """
            println("ok")
            """,
        )
        DistSSHBase._DETECT_JULIA_PATH_CACHE["host1"] = "/old/julia"
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
            added = DistSSHUp.juliaup_add_host!("host1", "1.13")
            @test added == (; host = "host1", channel = "1.13")
            @test DistSSHBase._DETECT_JULIA_PATH_CACHE["host1"] == "/old/julia"
            switched = DistSSHUp.juliaup_default_host!("host1", "1.13")
            @test switched.channel == "1.13"
            @test !haskey(DistSSHBase._DETECT_JULIA_PATH_CACHE, "host1")
        end
        write(
            ssh,
            """
            println("     *  1.13     1.13.2+0")
            println("      release     1.11.6+0")
            """,
        )
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
            lines = DistSSHUp.juliaup_status_lines("host1"; channel = "release")
            @test length(lines) == 1
            @test startswith(lines[1], "release")
        end
        write(
            ssh,
            """
            println(stderr, "juliaup default 1.13 failed")
            exit(1)
            """,
        )
        DistSSHBase._DETECT_JULIA_PATH_CACHE["host1"] = "/kept"
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
            @test_throws ErrorException DistSSHUp.juliaup_default_host!("host1", "1.13")
            @test DistSSHBase._DETECT_JULIA_PATH_CACHE["host1"] == "/kept"
        end
        delete!(DistSSHBase._DETECT_JULIA_PATH_CACHE, "host1")
    end
end
