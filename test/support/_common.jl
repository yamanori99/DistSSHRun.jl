# Loaded first from support.jl (same role as DistSSHRun/core/drive/_common.jl).
# Guard: JETLS may analyze this file both via support.jl and as an include leaf.

if !isdefined(Main, :_test_root)
    include(joinpath(@__DIR__, "..", "..", "src", "cli", "_checkout.jl"))

    function _test_root()::String
        return abspath(joinpath(@__DIR__, ".."))
    end

    function _kit_root()::String
        return abspath(joinpath(@__DIR__, "..", ".."))
    end

    _julia_exe()::String = joinpath(Sys.BINDIR, Base.julia_exename())
    _fixture(name::AbstractString) = joinpath(_test_root(), "fixtures", name)

    # `Base.julia_cmd()` carries the parent coverage and bounds flags.
    # `julia` replaces the executable when a test names another binary.
    function _julia_cmd_for(julia::AbstractString = _julia_exe())::Cmd
        cmd = Base.julia_cmd()
        exe = abspath(String(julia))
        abspath(cmd.exec[1]) == exe && return cmd
        rest = String[String(x) for x in cmd.exec[2:end]]
        return Cmd(vcat(String[exe], rest))
    end

    # `--project` for `julia -m DistSSHRun`. `TEST_PROJECT` is the process
    # startup project (`test/runtests.jl`, before any include). Do not read
    # `Base.active_project()` here: `drive!` activates the host and leaves it.
    function _cli_m_project(project::AbstractString)::String
        isdefined(Main, :TEST_PROJECT) ||
            error("_cli_m_project($(project)): TEST_PROJECT is not set")
        return String(TEST_PROJECT::AbstractString)
    end

    # Kit CLI as a child `julia -m DistSSHRun`.
    function _kit_cli_cmd(
            args::AbstractVector{<:AbstractString};
            julia::AbstractString = _julia_exe(),
            project::AbstractString = _kit_root()
        )::Cmd
        proj = _cli_m_project(String(project))
        argv = String[String(a) for a in args]
        return `$(_julia_cmd_for(julia)) --startup-file=no --project=$proj -m DistSSHRun $argv`
    end

    # Temp go/drive/size/setup hosts file: comment, bare host, `4*host-b`.
    function _sample_hosts_file()::String
        path, io = mktemp()
        try
            write(io, "# lab hosts (machine tokens)\nhost-a\n4*host-b\n")
            close(io)
        catch
            close(io)
            rm(path; force = true)
            rethrow()
        end
        return path
    end

    function _sample_setup_hosts_file()::String
        path, io = mktemp()
        try
            write(io, "# setup hosts (plain names, no N* counts)\nhost-a\nhost-b\n")
            close(io)
        catch
            close(io)
            rm(path; force = true)
            rethrow()
        end
        return path
    end

    # Last `progress:` in `dir` (`kit.progress` even with `--no-log`) is `done`.
    function _assert_kit_progress_done(dir::AbstractString; kind::Symbol)
        rec = DistSSHRun.kit_progress_latest(dir)
        @test rec !== nothing
        rec === nothing && return
        @test rec.event === :done
        @test rec.kind === kind
        @test rec.ok === true
        return rec
    end

    # `test/runtests.jl` and `test/parallel.jl` select files with this and
    # `_distsshrun_short_skip`.
    function _distssh_test_group_enabled(sym::Symbol)::Bool
        raw = strip(get(ENV, "DISTSSH_TEST_GROUP", ""))
        isempty(raw) && return true
        g = lowercase(raw)
        g == "unit" && return sym === :unit
        g == "integration" && return sym === :integration
        error("test: invalid DISTSSH_TEST_GROUP=$(repr(raw)); want unit, integration, or unset")
    end

    # PkgEval's assertion build kills this suite around 45 minutes.
    # `DISTSSHRUN_TEST_SHORT=1` (or `JULIA_PKGEVAL=true`) drops the heavy
    # files listed here. Unset keeps every file.
    function _distsshrun_test_short()::Bool
        flag = lowercase(strip(get(ENV, "DISTSSHRUN_TEST_SHORT", "")))
        if flag in ("1", "true", "yes", "on")
            return true
        end
        return strip(get(ENV, "JULIA_PKGEVAL", "")) == "true"
    end

    # Record @test_skip (not `return`) when a tool or OS guard would drop a testset.
    function _test_skip_unless_git()::Bool
        Sys.which("git") !== nothing && return true
        @test_skip "git not in PATH"
        return false
    end

    function _test_skip_unless_ssh()::Bool
        Sys.which("ssh") !== nothing && return true
        @test_skip "ssh not in PATH"
        return false
    end

    # Stub `ssh` on PATH (exits 1) when OpenSSH is absent (PkgEval sandbox).
    function _with_ssh_stub_in_path(f::Function)
        stub_dir = mktempdir()
        return try
            stub = joinpath(stub_dir, "ssh")
            write(stub, "#!/bin/sh\nexit 1\n")
            chmod(stub, 0o755)
            sep = Sys.iswindows() ? ';' : ':'
            prev = get(ENV, "PATH", "")
            withenv("PATH" => stub_dir * sep * prev) do
                return f()
            end
        finally
            _rm_tempdir!(stub_dir)
        end
    end

    function _test_skip_unless_unix()::Bool
        Sys.isunix() && return true
        @test_skip "requires Unix (script/kill)"
        return false
    end

    const _DISTSSHRUN_SHORT_SKIP_PATHS = (
        "unit/DistSSHRun/core/drive/workers.jl",
        "unit/DistSSHRun/execute.jl",
        "unit/DistSSHRun/core/setup/checks.jl",
        "unit/DistSSHRun/core/setup/send_list.jl",
        "integration/cli/help.jl",
        "integration/setup/exit.jl",
        # Pseudo-TTY (`script`) suites: ordinary checkout CI keeps them.
        # PkgEval and Registry install set JULIA_PKGEVAL=true and skip them.
        "integration/setup/progress_tty.jl",
        "integration/drive/progress_tty.jl",
        "integration/drive/reuse_main_isolated.jl",
        "integration/drive/execute.jl",
        "integration/drive/interrupt_grace.jl",
        "integration/drive/pkg.jl",
        "integration/drive/log_via_script.jl",
        "integration/drive/log_via_module.jl",
        "integration/drive/pkg_develop.jl",
        "integration/demos/with_kit.jl",
        "integration/demos/without_kit.jl",
    )

    function _distsshrun_short_skipped(rel::AbstractString)::Bool
        _distsshrun_test_short() || return false
        return String(rel) in _DISTSSHRUN_SHORT_SKIP_PATHS
    end

    function _distsshrun_short_skip(rel::AbstractString)::Bool
        _distsshrun_short_skipped(rel) || return false
        println("  short: skip $rel")
        flush(stdout)
        return true
    end

    function _runtest_include_paths(runtests_src::AbstractString)::Vector{String}
        paths = String[m.captures[1] for m in eachmatch(r"_runtest_include\(\s*\"([^\"]+)\"", runtests_src)]
        isempty(paths) && error("test: no _runtest_include calls in runtests.jl source")
        return paths
    end

    function _runtest_selected_files(runtests_src::AbstractString)::Vector{String}
        selected = filter(_runtest_include_paths(runtests_src)) do rel
            _distssh_test_group_enabled(Symbol(first(splitpath(rel)))) && !_distsshrun_short_skipped(rel)
        end
        isempty(selected) && error("test: DISTSSH_TEST_GROUP and DISTSSHRUN_TEST_SHORT select no file")
        return selected
    end

    # Keep the detached-env count off the test console. `min_level=Debug`
    # also keeps the name list, which is not written at Info.
    function _capture_detached_env_log(f; min_level = Test.Logging.Info)
        return Test.collect_test_logs(f; min_level = min_level)
    end

    function _go_local_slot_label()::String
        return DistSSHRun._go_local_slot_label_base()
    end

    function _go_local_slot_dir(i::Integer = 1; multi::Bool = false)::String
        base = _go_local_slot_label()
        (multi || i > 1) && return "$base-$i"
        return base
    end

end
