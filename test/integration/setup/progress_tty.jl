using Test

# Pseudo-TTY (`script`) versus a pipe. The TTY default is `:progress`.
# A pipe is `:verbose`. `NO_COLOR` forces the non-TTY default, so this
# runner unsets it before `julia` starts.
#
# CI / `script` typescripts look like they stack many `check` spinner rows.
# That is the byte stream: each redraw is `\r` + line + `\e[K` with no
# newline. Turning `\r` into `\n` (see `tty_lines`) makes each frame its own
# log line. A live terminal overwrites the same row; `live_spinner_bar_peak`
# applies `\r` / `\e[K` and asserts at most one spinner bar is visible.

@testset "TTY progress keeps up status and setup --check lines" begin
    status_cmd = _kit_cli_cmd(["up", "status", "parent", "child:host1"])
    update_cmd = _kit_cli_cmd(["up", "update", "parent", "child:host1"])
    check_cmd = _kit_cli_cmd(["setup", "--check", "child:host1"])
    mktempdir() do dir
        ju = joinpath(dir, "juliaup")
        write(
            ju,
            """
            #!/bin/sh
            case "\$1" in
              --version) echo 'Juliaup 1.22.7'; exit 0 ;;
              status)
                printf '%s\\n' '     *  1.13     1.13.0+0.aarch64.apple.darwin14  1.13.3'
                exit 0
                ;;
              update) exit 0 ;;
              *) exit 1 ;;
            esac
            """,
        )
        chmod(ju, 0o755)
        ssh = joinpath(dir, "ssh.jl")
        write(
            ssh,
            """
            script = length(ARGS) < 2 ? "" : ARGS[2]
            if occursin("case x in x)", script)
                m = match(r"__DSR_POSIX_OK_[0-9a-fA-F]+__", script)
                m === nothing || println(m.match)
            elseif strip(script) == "echo \\\$SHELL"
                println("/bin/sh")
            elseif strip(script) == "echo ok"
                println("ok")
            elseif occursin("update", script)
                println("ok")
            else
                println("     *  1.13     1.13.0+0.aarch64.apple.darwin14  1.13.3")
            end
            """,
        )
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
            export DISTSSHKIT_TEST_SSH=$(sh_quote(ssh))
            export PATH=$(sh_quote(empty_path))
            export JULIA_LOAD_PATH=$(sh_quote(_child_load_path()))
            unset JULIA_PROJECT
            $(argv_line(status_cmd))
            echo '___SPLIT___'
            $(argv_line(update_cmd))
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

        function strip_ansi(s::AbstractString)
            return replace(String(s), r"\e\[[0-9;?]*[A-Za-z]" => "")
        end
        function tty_lines(s::AbstractString)
            # Log-style view: each `\r` redraw becomes its own line (CI look).
            return split(strip_ansi(replace(String(s), "\r" => "\n")), '\n')
        end
        function bar_line(line::AbstractString)
            return occursin("[K", line) ||
                occursin("━", line) ||
                occursin("╺", line) ||
                any(c -> occursin(c, line), "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
        end
        function spinner_bar_line(line::AbstractString)
            return any(c -> occursin(c, line), "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏") &&
                (occursin("━", line) || occursin("╺", line))
        end
        function message_line(line::AbstractString)
            return occursin("not found in PATH", line) || occursin("Prerequisites not met", line)
        end
        # Live TTY: `\r` returns to column 0; CSI K after that clears the row.
        # Snapshot after each erase / newline and track how many spinner bars
        # would be on screen at once (must stay ≤ 1).
        function live_spinner_bar_peak(raw::AbstractString)
            finished = String[]
            cur = Ref("")
            at_home = false
            peak = Ref(0)
            function note!()
                rows = strip_ansi.(
                    isempty(cur[]) ? finished : vcat(finished, String[cur[]]),
                )
                peak[] = max(peak[], count(spinner_bar_line, rows))
                return nothing
            end
            i = firstindex(raw)
            while i <= lastindex(raw)
                ch = raw[i]
                if ch == '\r'
                    at_home = true
                    i = nextind(raw, i)
                elseif ch == '\n'
                    push!(finished, cur[])
                    cur[] = ""
                    at_home = false
                    note!()
                    i = nextind(raw, i)
                elseif ch == '\e'
                    j = nextind(raw, i)
                    if j <= lastindex(raw) && raw[j] == '['
                        k = nextind(raw, j)
                        while k <= lastindex(raw) && !isletter(raw[k])
                            k = nextind(raw, k)
                        end
                        k <= lastindex(raw) || break
                        if raw[k] == 'K'
                            if at_home
                                cur[] = ""
                                at_home = false
                            end
                            note!()
                        end
                        i = nextind(raw, k)
                    else
                        i = j
                    end
                else
                    if at_home
                        cur[] = ""
                        at_home = false
                    end
                    cur[] *= string(ch)
                    i = nextind(raw, i)
                end
            end
            note!()
            return peak[]
        end

        pty = capture_pty(runner)
        parts = split(pty, "___SPLIT___")
        @test length(parts) == 3
        status_tty = length(parts) == 3 ? parts[1] : ""
        update_tty = length(parts) == 3 ? parts[2] : ""
        check_tty = length(parts) == 3 ? parts[3] : ""
        status_lines = tty_lines(status_tty)
        parent_rows = filter(l -> occursin("parent:", l) && occursin("installed", l), status_lines)
        child_rows = filter(l -> occursin("host1:", l) && occursin("installed", l), status_lines)
        @test !isempty(parent_rows)
        @test !isempty(child_rows)
        @test all(l -> !occursin("same as parent", l), parent_rows)
        @test any(l -> occursin("installed 1.13.0", l), child_rows)
        @test occursin("parent: ✓ juliaup update", strip_ansi(update_tty))
        @test occursin("host1: ✓ juliaup update", strip_ansi(update_tty))
        check_lines = tty_lines(check_tty)
        @test !any(l -> bar_line(l) && message_line(l), check_lines)
        @test any(l -> strip(l) == "✗ ssh not found in PATH" || strip(l) == "  ✗ ssh not found in PATH", check_lines)
        finals = filter(l -> occursin("Prerequisites not met", l), check_lines)
        @test length(finals) == 1
        @test finals[1] == "  Prerequisites not met. Fix issues above and retry."
        @test !bar_line(finals[1])
        @test !occursin("[K", finals[1])
        # Flattened log may list many `check` frames; the live screen never stacks them.
        @test count(spinner_bar_line, check_lines) >= 1
        @test live_spinner_bar_peak(check_tty) <= 1
        ssh_at = findfirst("ssh not found in PATH", check_tty)
        pre_at = findfirst("Prerequisites not met", check_tty)
        @test ssh_at !== nothing && pre_at !== nothing && first(ssh_at) < first(pre_at)
        @test !occursin("Checking prerequisites", check_tty)

        pipe_env = _child_julia_env(
            Dict(
                "DISTSSHKIT_TEST" => "1",
                "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju,
                "DISTSSHKIT_TEST_SSH" => ssh,
                "PATH" => empty_path,
            ),
        )
        delete!(pipe_env, "NO_COLOR")
        delete!(pipe_env, "DISTSSHKIT_QUIET")
        delete!(pipe_env, "DISTSSHKIT_PROGRESS")
        delete!(pipe_env, "DISTSSHKIT_VERBOSE")
        status_pipe = read(setenv(status_cmd, pipe_env), String)
        update_pipe = read(setenv(update_cmd, pipe_env), String)
        check_pipe = read(ignorestatus(setenv(check_cmd, pipe_env)), String)
        @test occursin("1.13.0", status_pipe)
        @test occursin("aarch64", status_pipe)
        @test occursin("parent:", status_pipe)
        @test occursin("host1:", status_pipe)
        @test any(l -> occursin("parent:", l) && occursin("installed", l) && !occursin("same as parent", l), tty_lines(status_pipe))
        @test any(l -> occursin("host1:", l) && occursin("installed 1.13.0", l), tty_lines(status_pipe))
        @test occursin("✓ juliaup update", update_pipe)
        @test !occursin("parent: ✓ juliaup", update_pipe)
        @test !occursin("host1: ✓ juliaup", update_pipe)
        @test occursin("Checking prerequisites", check_pipe)
        pipe_ssh = findfirst("ssh not found in PATH", check_pipe)
        pipe_pre = findfirst("Prerequisites not met", check_pipe)
        @test pipe_ssh !== nothing && pipe_pre !== nothing && first(pipe_ssh) < first(pipe_pre)
        pipe_finals = filter(l -> occursin("Prerequisites not met", l), tty_lines(check_pipe))
        @test length(pipe_finals) == 1
        @test pipe_finals[1] == "  Prerequisites not met. Fix issues above and retry."
    end
end
