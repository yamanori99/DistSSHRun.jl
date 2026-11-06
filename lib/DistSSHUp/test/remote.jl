using Test

@testset "remote shell" begin
    sh = DistSSHUp._juliaup_align_remote_sh("1.12")
    @test occursin(raw"$HOME/.juliaup/bin/juliaup", sh)
    @test occursin("/opt/homebrew/bin/juliaup", sh)
    @test occursin(" add ", sh) || occursin("add '", sh)
    @test occursin("update", sh) && occursin("default", sh)
    @test !occursin("echo already", sh)
    @test !occursin("\$1==\"*\"", sh)
    @test occursin("--version", sh)
    @test occursin("older than 1.22", sh)
    up_sh = DistSSHUp._juliaup_update_remote_sh()
    @test occursin(raw"$HOME/.juliaup/bin/juliaup", up_sh)
    @test occursin("\"\$JU\" update", up_sh)
    @test !occursin("echo already", up_sh)
    @test !occursin("default", up_sh)
    sh_meta = DistSSHUp._juliaup_align_remote_sh("1.12\$(id)")
    @test occursin("'1.12\$(id)'", sh_meta)
    @test !occursin("juliaup add 1.12\$(id) failed", sh_meta)
    add_sh = DistSSHUp._juliaup_add_remote_sh("1.13")
    @test occursin("add", add_sh)
    @test !occursin("default", add_sh)
    def_sh = DistSSHUp._juliaup_default_remote_sh("1.13")
    @test occursin("default", def_sh)
    one_sh = DistSSHUp._juliaup_update_channel_remote_sh("release")
    @test occursin("update", one_sh)
    @test !occursin("default", one_sh)

    mktempdir() do d
        log = joinpath(d, "log")
        ju = joinpath(d, "juliaup")
        write(
            ju,
            """
            #!/bin/sh
            echo "\$*" >> '$log'
            case "\$1" in
              --version) echo 'Juliaup 1.22.7'; exit 0 ;;
              status) echo '     *  1.13     1.13.0+0.aarch64.apple.darwin14'; exit 0 ;;
              add|update|default) exit 0 ;;
              *) exit 1 ;;
            esac
            """,
        )
        chmod(ju, 0o755)
        script = DistSSHUp._juliaup_align_remote_sh("1.13"; candidates = [ju])
        @test !occursin("echo already", script)
        run(pipeline(`sh -c $script`; stdout = devnull, stderr = devnull))
        logged = read(log, String)
        @test count(==("update 1.13"), split(logged, '\n'; keepempty = false)) == 1
    end
end
