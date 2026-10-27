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

    @testset "non-POSIX login shell is diagnosed only after a failure" begin
        double = joinpath(@__DIR__, "fixtures", "fake_shell_ssh.jl")
        probe_pat = r"case x in x\) echo __DSR_POSIX_OK_[0-9a-fA-F]+__;; esac"
        function logged(path::AbstractString)::Vector{String}
            isfile(path) || return String[]
            return split(read(path, String), '\n'; keepempty = false)
        end
        probe_line(line::AbstractString) = occursin(probe_pat, line)
        function shell_env(logp::AbstractString; mode::AbstractString = "posix", noise::Bool = false)
            return Dict(
                "DISTSSHKIT_TEST" => "1",
                "DISTSSHKIT_TEST_SSH" => double,
                "SHELL_DOUBLE_LOG" => logp,
                "SHELL_DOUBLE_MODE" => String(mode),
                "SHELL_DOUBLE_NOISE" => noise ? "1" : "0",
                "DISTSSHKIT_TEST_POSIX_SHELL" => mode == "fish" ? "0" : "1",
            )
        end

        @test _BASE._remote_shell_host_from_exec(
            ["/usr/bin/ssh", "-n", "--", "h.test", "true"],
        ) == "h.test"
        @test _BASE._remote_shell_host_from_exec(
            ["/usr/bin/ssh", "-G", "--", "h.test"],
        ) === nothing

        probe = _BASE._posix_probe_script("abc")
        @test !occursin("\$SHELL", probe)
        @test probe != _BASE._REMOTE_SHELL_NAME_SCRIPT
        sh_proc, sh_out = _run_subprocess(`/bin/sh -c $probe`)
        @test sh_proc.exitcode == 0
        @test occursin("__DSR_POSIX_OK_abc__", sh_out)
        fish = Sys.which("fish")
        if fish !== nothing
            fish_proc, fish_out = _run_subprocess(`$fish -c $probe`)
            @test fish_proc.exitcode != 0
            @test !occursin("__DSR_POSIX_OK_abc__", fish_out)
        end

        _with_tempdir() do dir
            logp = joinpath(dir, "ssh.log")
            try
                withenv(shell_env(logp)...) do
                    code, out = _BASE._remote_shell_status("posix-ok.test", "ok")
                    @test code == 0
                    @test strip(out) == "ok"
                end
                @test !any(probe_line, logged(logp))

                rm(logp; force = true)
                withenv(shell_env(logp)...) do
                    code, out = _BASE._remote_shell_status("posix-fail.test", "nope")
                    @test code == 9
                    @test out == ""
                    @test any(probe_line, logged(logp))
                    rm(logp; force = true)
                    code2, _ = _BASE._remote_shell_status("posix-fail.test", "nope")
                    @test code2 == 9
                end
                lines = logged(logp)
                @test lines == ["nope"]
                @test !any(probe_line, lines)

                rm(logp; force = true)
                withenv(shell_env(logp; noise = true)...) do
                    code, _ = _BASE._remote_shell_status("posix-noise.test", "nope")
                    @test code == 9
                end
                @test any(probe_line, logged(logp))

                rm(logp; force = true)
                withenv(shell_env(logp)...) do
                    err = try
                        _BASE._remote_shell_status("posix-255.test", "sshfail")
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test !occursin("non-POSIX", err.msg)
                    @test !occursin("--help", err.msg)
                end
                @test !any(probe_line, logged(logp))

                rm(logp; force = true)
                withenv(shell_env(logp; mode = "probe255")...) do
                    code, _ = _BASE._remote_shell_status("probe-unknown.test", "nope")
                    @test code == 9
                end
                unknown_lines = logged(logp)
                @test any(probe_line, unknown_lines)
                @test !any(==(_BASE._REMOTE_SHELL_NAME_SCRIPT), unknown_lines)

                rm(logp; force = true)
                fish_host = "fish.test"
                withenv(shell_env(logp; mode = "fish")...) do
                    err = try
                        _BASE._remote_shell_status(fish_host, "nope")
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test occursin("remote command on $(fish_host) failed (exit 9):", err.msg)
                    @test occursin("missing-tool", err.msg)
                    @test occursin("non-POSIX (/usr/bin/fish)", err.msg)
                    @test occursin("help setup", err.msg)
                    @test !occursin("--help", err.msg)
                    err2 = try
                        _BASE._remote_shell_status(fish_host, "nope")
                        nothing
                    catch e
                        e
                    end
                    @test err2 isa ArgumentError
                    @test occursin("non-POSIX (/usr/bin/fish)", err2.msg)
                end
                fish_lines = logged(logp)
                @test count(probe_line, fish_lines) == 2
                @test count(==(_BASE._REMOTE_SHELL_NAME_SCRIPT), fish_lines) == 2
                @test !any(line -> occursin("case x in", line) && occursin("echo \$SHELL", line), fish_lines)

                rm(logp; force = true)
                withenv(shell_env(logp; mode = "fish")...) do
                    cmd = _BASE._host_sync_remote_shell_cmd("summarize-fish.test", "nope")
                    proc = run(ignorestatus(cmd); wait = true)
                    @test proc.exitcode == 9
                    msg = _BASE.summarize_ssh_error(
                        Base.ProcessFailedException(Base.Process[proc]);
                        stderr = "missing-tool",
                    )
                    @test startswith(msg, "missing-tool")
                    @test occursin("non-POSIX (/usr/bin/fish)", msg)
                    @test occursin("help setup", msg)
                    @test !occursin("--help", msg)
                    sshfail = _BASE._host_sync_remote_shell_cmd("summarize-255.test", "sshfail")
                    denied = run(ignorestatus(sshfail); wait = true)
                    @test denied.exitcode == 255
                    plain = _BASE.summarize_ssh_error(
                        Base.ProcessFailedException(Base.Process[denied]);
                        stderr = "Permission denied (publickey).",
                    )
                    @test !occursin("non-POSIX", plain)
                    @test occursin("ssh-copy-id", plain)
                end

                rm(logp; force = true)
                withenv(shell_env(logp)...) do
                    hints = Vector{Union{Nothing, String}}(undef, 2)
                    @sync begin
                        Threads.@spawn begin
                            hints[1] = _BASE._remote_shell_failure_hint("posix-threads.test", 9)
                        end
                        Threads.@spawn begin
                            hints[2] = _BASE._remote_shell_failure_hint("posix-threads.test", 9)
                        end
                    end
                    @test hints[1] === nothing
                    @test hints[2] === nothing
                    @test _BASE._remote_posix_shell_cached("posix-threads.test")
                end
            finally
                _BASE._clear_remote_posix_shell_cache!()
            end
        end
    end
end
