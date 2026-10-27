using Test

let _BASE = DistSSHBase
    @testset "remote shell quotes metacharacters" begin
        @test _BASE._remote_shell_path_word("/srv/x;id") == "'/srv/x;id'"
        @test _BASE._remote_shell_path_word("~/Repo") == "~/'Repo'"
        @test _BASE._remote_shell_path_word("~/a/b c") == "~/'a/b c'"
        @test _BASE._ssh_host_args("host", "true") == ["--", "host", "true"]
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

        home = raw"$HOME/.juliaup/bin/julia"
        @test _BASE._remote_julia_version_remote_command(home) ==
            "\"\$HOME/.juliaup/bin/julia\" --version"
    end

    @testset "posix login shell probe" begin
        @test _BASE._remote_posix_probe_accepted(0, "ok\n")
        @test _BASE._remote_posix_probe_accepted(0, "ok")
        @test !_BASE._remote_posix_probe_accepted(0, "ok\nextra")
        @test !_BASE._remote_posix_probe_accepted(127, "ok")
        @test !_BASE._remote_posix_probe_accepted(255, "ok")
        @test _BASE._POSIX_SHELL_PROBE == "case x in x) echo ok;; esac"
        proc, out = _run_subprocess(`/bin/sh -c $(_BASE._POSIX_SHELL_PROBE)`)
        @test proc.exitcode == 0
        @test strip(out) == "ok"

        _with_tempdir() do state_dir
            logp = joinpath(state_dir, "ssh.log")
            env = merge(
                _fake_setup_remote_env(state_dir),
                Dict("DISTSSHKIT_TEST_SSH_LOG" => logp),
            )
            withenv(env...) do
                host = "posix-host.test"
                _BASE._clear_remote_posix_shell_cache!(host)
                _BASE._ensure_remote_posix_shell(host)
                first = read(logp, String)
                _BASE._ensure_remote_posix_shell(host)
                second = read(logp, String)
                @test first == second
                @test count(line -> occursin("case x in x)", line), eachline(IOBuffer(first))) == 1
                @test _BASE._remote_posix_shell_cached(host)
            end
            withenv(merge(env, Dict("DISTSSHKIT_TEST_POSIX_SHELL" => "0"))...) do
                host = "fish-host.test"
                _BASE._clear_remote_posix_shell_cache!(host)
                err = try
                    _BASE._ensure_remote_posix_shell(host)
                    nothing
                catch e
                    e
                end
                @test err isa ArgumentError
                msg = err isa ArgumentError ? err.msg : ""
                @test occursin("not POSIX-compatible", msg)
                @test occursin("\$SHELL -c", msg)
                @test occursin("sh -l -c", msg)
                @test occursin("fish", msg)
                @test occursin("help setup", msg)
                @test !occursin("--help", msg)
                err2 = try
                    _BASE._ensure_remote_posix_shell(host)
                    nothing
                catch e
                    e
                end
                @test err2 isa ArgumentError
                @test !_BASE._remote_posix_shell_cached(host)
            end
            withenv(merge(env, Dict("DISTSSHKIT_TEST_SSH_FAIL" => "1"))...) do
                host = "down-host.test"
                _BASE._clear_remote_posix_shell_cache!(host)
                @test _BASE._ensure_remote_posix_shell(host) === nothing
                @test !_BASE._remote_posix_shell_cached(host)
            end
        end
    end

    @testset "remote path forbidden" begin
        @test _BASE._remote_path_forbidden("~/../u")
        @test _BASE._remote_path_forbidden("/a/../b")
        @test !_BASE._remote_path_forbidden("~/a/proj")
    end
end
