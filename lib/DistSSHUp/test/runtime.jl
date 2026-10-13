using Test

# Contract the rest of the family calls. Fake juliaup and a Julia SSH double.
# A failed step must not move the default. A finished align must read a version.

function _this_channel()::String
    return "$(VERSION.major).$(VERSION.minor)"
end

function _this_version_line()::String
    return "julia version $(VERSION.major).$(VERSION.minor).$(VERSION.patch)"
end

function _write_sh(path::AbstractString, body::AbstractString)
    write(path, "#!/bin/sh\n" * body)
    chmod(path, 0o755)
    return path
end

function _logged_juliaup(path::AbstractString, log::AbstractString, arms::AbstractString)
    return _write_sh(
        path,
        """
        echo "\$*" >> '$log'
        case "\$1" in
          --version) echo 'Juliaup 1.22.7'; exit 0 ;;
        $arms
          *) exit 1 ;;
        esac
        """,
    )
end

function _write_julia_beside(dir::AbstractString, line::AbstractString)
    jl = joinpath(dir, "julia")
    _write_sh(jl, "echo '$line'\n")
    return jl
end

function _write_ssh_double(
        path::AbstractString;
        version_line::AbstractString = _this_version_line(),
        found::Bool = true,
    )
    found_body = found ? """
        if script == "uname -s"
            println("Linux")
        elseif startswith(script, "test -x")
            occursin("/usr/bin/julia", script) && println("/usr/bin/julia")
        elseif script == "command -v julia || which julia"
            println("/usr/bin/julia")
        elseif occursin("--version", script) && !occursin("echo already", script)
            println($(repr(version_line)))
        else
            println("ok")
        end
        """ : """
        if script == "uname -s" || startswith(script, "test -x") ||
                script == "command -v julia || which julia"
            exit(1)
        end
        println("ok")
        """
    write(
        path,
        """
        script = length(ARGS) < 2 ? "" : ARGS[2]
        $found_body
        """,
    )
    return path
end

function _err_msg(f)::String
    try
        f()
        return ""
    catch e
        return e isa ErrorException ? e.msg : sprint(showerror, e)
    end
end

@testset "runtime contract" begin
    ch = _this_channel()

    @testset "local verbs do not move the default by accident" begin
        mktempdir() do d
            log = joinpath(d, "log")
            ju = joinpath(d, "juliaup")
            _logged_juliaup(
                ju, log, """
                  add) exit 0 ;;
                  default) exit 0 ;;
                  update) exit 0 ;;
                  status) echo '      $ch     $ch.1+0'; exit 0 ;;
                """,
            )
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                DistSSHUp.juliaup_add_local!(ch)
                add_log = read(log, String)
                @test occursin("add $ch", add_log)
                @test !occursin("default", add_log)
                rm(log)
                DistSSHUp.juliaup_update_local!()
                all_log = read(log, String)
                @test occursin("\nupdate\n", "\n" * all_log)
                @test !occursin("update $ch", all_log)
                @test !occursin("default", all_log)
                rm(log)
                DistSSHUp.juliaup_update_local!(ch)
                one_log = read(log, String)
                @test occursin("update $ch", one_log)
                @test !occursin("default", one_log)
                rm(log)
                DistSSHUp.juliaup_default_local!(ch)
                def_log = read(log, String)
                @test occursin("default $ch", def_log)
                @test !occursin("update", def_log)
            end
        end
    end

    @testset "add treats an installed channel as success" begin
        mktempdir() do d
            log = joinpath(d, "log")
            ju = joinpath(d, "juliaup")
            _logged_juliaup(
                ju, log, """
                  add) echo 'already installed' >&2; exit 1 ;;
                  status) echo '      $ch     $ch.1+0'; exit 0 ;;
                """,
            )
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                @test DistSSHUp.juliaup_add_local!(ch) === nothing
                @test !occursin("default", read(log, String))
            end
        end
        mktempdir() do d
            ju = joinpath(d, "juliaup")
            _write_sh(
                ju,
                """
                case "\$1" in
                  --version) echo 'Juliaup 1.22.7'; exit 0 ;;
                  add) echo 'first' >&2; echo 'second' >&2; exit 1 ;;
                  status) echo 'empty'; exit 0 ;;
                  *) exit 1 ;;
                esac
                """,
            )
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                @test _err_msg(() -> DistSSHUp.juliaup_add_local!(ch)) == "first"
            end
        end
    end

    @testset "a failed update does not run default" begin
        mktempdir() do d
            log = joinpath(d, "log")
            ju = joinpath(d, "juliaup")
            _logged_juliaup(
                ju, log, """
                  add) exit 0 ;;
                  update) printf 'update broke\\nmore\\n' >&2; exit 1 ;;
                  default) exit 0 ;;
                  status) echo 'no'; exit 0 ;;
                """,
            )
            _write_julia_beside(d, _this_version_line())
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                @test _err_msg(() -> DistSSHUp.juliaup_align_local!(ch)) == "update broke"
                seen = read(log, String)
                @test occursin("add $ch", seen)
                @test occursin("update $ch", seen)
                @test !occursin("default", seen)
                @test _err_msg(() -> DistSSHUp.juliaup_update_local!()) == "update broke"
            end
        end
        mktempdir() do d
            ju = joinpath(d, "juliaup")
            _write_sh(
                ju,
                """
                case "\$1" in
                  --version) echo 'Juliaup 1.22.7'; exit 0 ;;
                  update) exit 3 ;;
                  *) exit 1 ;;
                esac
                """,
            )
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                @test occursin("exit 3", _err_msg(() -> DistSSHUp.juliaup_update_local!(ch)))
            end
        end
    end

    @testset "default fails closed when the channel is missing" begin
        mktempdir() do d
            ju = joinpath(d, "juliaup")
            _write_sh(
                ju,
                """
                case "\$1" in
                  --version) echo 'Juliaup 1.22.7'; exit 0 ;;
                  default) echo 'error: not installed' >&2; exit 1 ;;
                  *) exit 1 ;;
                esac
                """,
            )
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                DistSSHBase._DETECT_JULIA_PATH_CACHE["parent"] = "/kept"
                @test _err_msg(() -> DistSSHUp.juliaup_default_local!(ch)) == "error: not installed"
                @test _err_msg(() -> DistSSHUp.juliaup_default_host!("parent", ch)) ==
                    "error: not installed"
                @test DistSSHBase._DETECT_JULIA_PATH_CACHE["parent"] == "/kept"
                delete!(DistSSHBase._DETECT_JULIA_PATH_CACHE, "parent")
            end
        end
    end

    @testset "align checks the Julia it left behind" begin
        mktempdir() do d
            ju = joinpath(d, "juliaup")
            _write_sh(
                ju,
                """
                case "\$1" in
                  --version) echo 'Juliaup 1.22.7'; exit 0 ;;
                  add|update|default) exit 0 ;;
                  status) echo 'no'; exit 0 ;;
                  *) exit 1 ;;
                esac
                """,
            )
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                @test occursin(
                    "Julia not found",
                    _err_msg(() -> DistSSHUp.juliaup_align_local!(ch)),
                )
            end
            _write_julia_beside(d, "not a version")
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                @test occursin(
                    "unparseable",
                    _err_msg(() -> DistSSHUp.juliaup_align_local!(ch)),
                )
            end
            other = VersionNumber(VERSION.major, VERSION.minor + 1, 0)
            _write_julia_beside(d, "julia version $other")
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                msg = _err_msg(() -> DistSSHUp.juliaup_align_local!(ch))
                @test occursin("still mismatched", msg)
                @test occursin(string(VERSION), msg)
                @test occursin(string(other), msg)
            end
        end
    end

    @testset "add during align may already be installed" begin
        mktempdir() do d
            log = joinpath(d, "log")
            ju = joinpath(d, "juliaup")
            _logged_juliaup(
                ju, log, """
                  add) echo 'present' >&2; exit 1 ;;
                  status) echo '      $ch     $ch.1+0'; exit 0 ;;
                  update|default) exit 0 ;;
                """,
            )
            _write_julia_beside(d, _this_version_line())
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                r = DistSSHUp.juliaup_align_local!(ch)
                @test r.changed
                @test DistSSHUp.julia_version_mismatch_kind(VERSION, r.ver) != :minor
                @test occursin("default $ch", read(log, String))
            end
        end
    end

    @testset "missing or old juliaup fails before any verb" begin
        mktempdir() do d
            missing = joinpath(d, "missing")
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => missing) do
                @test occursin("juliaup not found", _err_msg(() -> DistSSHUp.juliaup_add_local!(ch)))
                @test DistSSHUp.juliaup_status_lines("parent") == String[]
                @test DistSSHUp.juliaup_default_patch("parent") == "-"
            end
            ju = joinpath(d, "juliaup")
            _write_sh(ju, "echo 'Juliaup 1.21.0'\n")
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                @test occursin("older than 1.22", _err_msg(() -> DistSSHUp.juliaup_default_local!(ch)))
                @test occursin("older than 1.22", _err_msg(() -> DistSSHUp.juliaup_add_local!(ch)))
            end
            _write_sh(
                ju,
                """
                case "\$1" in
                  --version) echo 'not juliaup'; exit 0 ;;
                  *) exit 1 ;;
                esac
                """,
            )
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                @test occursin("unreadable", _err_msg(() -> DistSSHUp.juliaup_update_local!()))
            end
        end
    end

    @testset "status hides a dead juliaup and keeps real rows" begin
        mktempdir() do d
            ju = joinpath(d, "juliaup")
            _write_sh(
                ju,
                """
                case "\$1" in
                  status) exit 1 ;;
                  *) exit 1 ;;
                esac
                """,
            )
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                @test DistSSHUp.juliaup_status_lines("parent") == String[]
                @test DistSSHUp.juliaup_default_patch("parent") == "-"
            end
            _write_sh(
                ju,
                """
                echo 'Default  Channel  Version'
                echo '-------------------------'
                echo '     *  $ch     $ch.4+0.aarch64'
                echo '      release     1.11.6+0'
                """,
            )
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                rows = DistSSHUp.juliaup_status_lines("parent")
                @test length(rows) == 2
                @test !any(startswith(row, "Default") || startswith(row, "-") for row in rows)
                @test DistSSHUp.juliaup_default_patch("parent") == "$ch.4"
            end
        end
    end

    @testset "remote align reads the Julia it switched to" begin
        mktempdir() do d
            ssh = joinpath(d, "ssh.jl")
            DistSSHBase.clear_detect_julia_path_cache!("align-host")
            DistSSHBase._DETECT_JULIA_PATH_CACHE["align-host"] = "/stale"
            _write_ssh_double(ssh)
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
                r = DistSSHUp.juliaup_align_host!("align-host"; channel = ch)
                @test r.host == "align-host"
                @test !r.already
                @test r.ver isa VersionNumber
                @test DistSSHUp.julia_version_mismatch_kind(VERSION, r.ver) != :minor
                @test DistSSHBase._DETECT_JULIA_PATH_CACHE["align-host"] == "/usr/bin/julia"
            end
            other = VersionNumber(VERSION.major, VERSION.minor + 1, 0)
            _write_ssh_double(ssh; version_line = "julia version $other")
            DistSSHBase.clear_detect_julia_path_cache!("align-host")
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
                msg = _err_msg(() -> DistSSHUp.juliaup_align_host!("align-host"; channel = ch))
                @test occursin("still mismatched", msg)
                @test occursin(string(other), msg)
            end
            _write_ssh_double(ssh; found = false)
            DistSSHBase.clear_detect_julia_path_cache!("align-host")
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
                @test occursin(
                    "Julia not found",
                    _err_msg(() -> DistSSHUp.juliaup_align_host!("align-host"; channel = ch)),
                )
            end
            write(
                ssh,
                """
                println("already")
                """,
            )
            DistSSHBase._DETECT_JULIA_PATH_CACHE["align-host"] = "/kept"
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
                r = DistSSHUp.juliaup_align_host!("align-host"; channel = ch)
                @test r.already
                @test r.ver === nothing
                @test DistSSHBase._DETECT_JULIA_PATH_CACHE["align-host"] == "/kept"
            end
            delete!(DistSSHBase._DETECT_JULIA_PATH_CACHE, "align-host")
        end
    end

    @testset "remote errors stay on the first line and status stays quiet" begin
        mktempdir() do d
            ssh = joinpath(d, "ssh.jl")
            write(
                ssh,
                """
                println(stderr, "line1")
                println(stderr, "line2")
                exit(1)
                """,
            )
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
                @test _err_msg(() -> DistSSHUp.juliaup_update_host!("quiet-host")) == "line1"
                @test DistSSHUp.juliaup_status_lines("quiet-host") == String[]
            end
            write(ssh, "exit(2)\n")
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
                @test _err_msg(() -> DistSSHUp.juliaup_add_host!("quiet-host", ch)) == "exit 2"
            end
            write(
                ssh,
                """
                println("ok")
                """,
            )
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_SSH" => ssh) do
                @test DistSSHUp.juliaup_update_host!("quiet-host"; channel = "release").host ==
                    "quiet-host"
            end
        end
    end

end
