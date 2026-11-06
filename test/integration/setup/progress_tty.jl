using Test

# Pseudo-TTY (`script`) versus a pipe. The TTY default is `:progress`.
# A pipe is `:verbose`. `NO_COLOR` forces the non-TTY default, so this
# runner unsets it before `julia` starts.

@testset "TTY progress keeps up status and setup --check lines" begin
    status_cmd = _kit_cli_cmd(["up", "status", "parent"])
    check_cmd = _kit_cli_cmd(["setup", "--check", "child:host1"])
    mktempdir() do dir
        ju = joinpath(dir, "juliaup")
        write(
            ju,
            """
            #!/bin/sh
            case "\$1" in
              status)
                printf '%s\\n' '     *  1.13     1.13.0+0.aarch64.apple.darwin14  1.13.3'
                exit 0
                ;;
              *) exit 1 ;;
            esac
            """,
        )
        chmod(ju, 0o755)
        empty_path = mktempdir()
        runner = joinpath(dir, "runner.sh")
        function sh_quote(s::AbstractString)
            return "'" * replace(String(s), "'" => "'\\''") * "'"
        end
        function argv_line(cmd::Cmd)
            return join(sh_quote.(String.(cmd.exec)), " ")
        end
        write(
            runner,
            """
            #!/bin/sh
            unset NO_COLOR
            unset DISTSSHKIT_QUIET
            unset DISTSSHKIT_PROGRESS
            unset DISTSSHKIT_VERBOSE
            unset DISTSSHKIT_CLI_SUBCOMMAND_DONE
            unset DIST_SSH_KIT_CLI_INCLUDE
            export DISTSSHKIT_TEST=1
            export DISTSSHKIT_TEST_LOCAL_JULIAUP=$(sh_quote(ju))
            export PATH=$(sh_quote(empty_path))
            export JULIA_LOAD_PATH=$(sh_quote(_child_load_path()))
            unset JULIA_PROJECT
            $(argv_line(status_cmd))
            echo '___SPLIT___'
            $(argv_line(check_cmd))
            """,
        )
        chmod(runner, 0o755)

        function capture_pty(script_path::AbstractString)
            dest = joinpath(dir, "typescript.txt")
            rm(dest; force = true)
            cmd = if Sys.isapple()
                `script -q $dest /bin/sh $script_path`
            else
                `script -q -c $script_path $dest`
            end
            skip = (
                "NO_COLOR",
                "JULIA_LOAD_PATH",
                "JULIA_PROJECT",
                "DISTSSHKIT_CLI_SUBCOMMAND_DONE",
                "DIST_SSH_KIT_CLI_INCLUDE",
            )
            env = Dict{String, String}(
                String(k) => String(v) for (k, v) in ENV if !(String(k) in skip) && !isempty(v)
            )
            run(ignorestatus(setenv(cmd, env)))
            return isfile(dest) ? read(dest, String) : ""
        end

        pty = capture_pty(runner)
        parts = split(pty, "___SPLIT___")
        @test length(parts) == 2
        status_tty = length(parts) == 2 ? parts[1] : ""
        check_tty = length(parts) == 2 ? parts[2] : ""
        @test occursin("1.13.0", status_tty)
        @test occursin("parent", status_tty)
        ssh_at = findfirst("ssh not found in PATH", check_tty)
        pre_at = findfirst("Prerequisites not met", check_tty)
        @test ssh_at !== nothing && pre_at !== nothing && first(ssh_at) < first(pre_at)
        @test !occursin("Checking prerequisites", check_tty)

        pipe_env = _child_julia_env(
            Dict(
                "DISTSSHKIT_TEST" => "1",
                "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju,
                "PATH" => empty_path,
            ),
        )
        delete!(pipe_env, "NO_COLOR")
        delete!(pipe_env, "DISTSSHKIT_QUIET")
        delete!(pipe_env, "DISTSSHKIT_PROGRESS")
        delete!(pipe_env, "DISTSSHKIT_VERBOSE")
        status_pipe = read(setenv(status_cmd, pipe_env), String)
        check_pipe = read(ignorestatus(setenv(check_cmd, pipe_env)), String)
        @test occursin("1.13.0", status_pipe)
        @test occursin("aarch64", status_pipe)
        @test occursin("Checking prerequisites", check_pipe)
        pipe_ssh = findfirst("ssh not found in PATH", check_pipe)
        pipe_pre = findfirst("Prerequisites not met", check_pipe)
        @test pipe_ssh !== nothing && pipe_pre !== nothing && first(pipe_ssh) < first(pipe_pre)
    end
end
