using Test

let _BASE = DistSSHBase
    @testset "remote shell quotes metacharacters" begin
        @test _BASE._remote_shell_path_word("/srv/x;id") == "'/srv/x;id'"
        @test _BASE._remote_shell_path_word("~/Repo") == "~/'Repo'"
        @test _BASE._remote_shell_path_word("~/a/b c") == "~/'a/b c'"
        @test _BASE._ssh_host_args("host", "true") == ["--", "host", "true"]
        @test_throws ArgumentError _BASE._ssh_host_args("-oBatchMode=yes", "true")
        @test_throws ArgumentError _BASE._ssh_host_args("user@-h", "true")
        @test_throws ArgumentError _BASE._ssh_host_args("host:/tmp/a\nb")
        @test _BASE._ssh_host_args("user@host:/tmp/a b") == ["--", "user@host:/tmp/a b"]
        @test_throws ArgumentError _BASE.ssh_addprocs_machine("-worker")
    end

    @testset "julia --version path is one shell word" begin
        path = "/opt/My Julia/bin/julia"
        remote = _BASE._remote_julia_version_remote_command(path)
        @test remote == "'/opt/My Julia/bin/julia' --version"
        @test _BASE._ssh_host_args("host.example", remote) == ["--", "host.example", remote]
        script = "set -- " * remote * "; printf '%s\\n%s' \"\$1\" \"\$2\""
        proc, out = _run_subprocess(`/bin/sh -c $script`)
        @test proc.exitcode == 0
        @test out == path * "\n--version"

        tricky = "/tmp/julia;echo pwned"
        tricky_remote = _BASE._remote_julia_version_remote_command(tricky)
        tricky_script = "set -- " * tricky_remote * "; printf %s \"\$1\""
        proc2, out2 = _run_subprocess(`/bin/sh -c $tricky_script`)
        @test proc2.exitcode == 0
        @test out2 == tricky

        apostrophe = "/opt/o'brien/bin/julia"
        apostrophe_remote = _BASE._remote_julia_version_remote_command(apostrophe)
        @test apostrophe_remote == "'/opt/o'\\''brien/bin/julia' --version"
        apostrophe_script = "set -- " * apostrophe_remote * "; printf '%s\\n%s' \"\$1\" \"\$2\""
        proc3, out3 = _run_subprocess(`/bin/sh -c $apostrophe_script`)
        @test proc3.exitcode == 0
        @test out3 == apostrophe * "\n--version"

        home = raw"$HOME/.juliaup/bin/julia"
        @test _BASE._remote_julia_version_remote_command(home) ==
            "\"\$HOME/.juliaup/bin/julia\" --version"
        tilde = "~/julia-1.x/bin/julia"
        @test _BASE._remote_julia_version_remote_command(tilde) ==
            "\"\$HOME/julia-1.x/bin/julia\" --version"
        special = "\$HOME/a`b c\"d\$e\\f"
        @test _BASE._remote_julia_version_remote_command(special) ==
            "\"\$HOME/a\\`b c\\\"d\\\$e\\\\f\" --version"

        home_dir = "/tmp/distssh-quote-home"
        for (spec, expanded) in (
                home => home_dir * "/.juliaup/bin/julia",
                tilde => home_dir * "/julia-1.x/bin/julia",
                "~/My Julia's/bin/julia" => home_dir * "/My Julia's/bin/julia",
                special => home_dir * "/a`b c\"d\$e\\f",
            )
            remote = _BASE._remote_julia_version_remote_command(spec)
            script = "set -- " * remote * "; printf '%s\\n%s' \"\$1\" \"\$2\""
            proc_h, out_h = _run_subprocess(setenv(`/bin/sh -c $script`, "HOME" => home_dir))
            @test proc_h.exitcode == 0
            @test out_h == expanded * "\n--version"
        end
    end

    @testset "remote path forbidden" begin
        @test _BASE._remote_path_forbidden("~/../u")
        @test _BASE._remote_path_forbidden("/a/../b")
        @test !_BASE._remote_path_forbidden("~/a/proj")
    end
end
