# Loaded first from support.jl (same role as DistSSHRun/core/drive/_common.jl).
# Guard: JETLS may analyze this file both via support.jl and as an include leaf.

if !isdefined(@__MODULE__, :_test_root)
    include(joinpath(@__DIR__, "..", "..", "src", "cli", "_checkout.jl"))

    function _test_root()::String
        return abspath(joinpath(@__DIR__, ".."))
    end

    function _kit_root()::String
        return abspath(joinpath(@__DIR__, "..", ".."))
    end

    _julia_exe()::String = joinpath(Sys.BINDIR, Base.julia_exename())
    _fixture(name::AbstractString) = joinpath(_test_root(), "fixtures", name)

    # `Base.julia_cmd()` carries the parent coverage and bounds flags. Drop
    # unscoped `--code-coverage` so child kit CLIs do not instrument suite
    # trees (`user` / `all` write `.cov` beside shipped project files).
    # Scoped `@path` flags from E2E stay so remote paths still hit Codecov.
    function _strip_unscoped_coverage_flags(parts::AbstractVector{<:AbstractString})::Vector{String}
        out = String[]
        i = 1
        n = length(parts)
        while i <= n
            p = String(parts[i])
            if p == "--code-coverage" || p == "--code-coverage=user" || p == "--code-coverage=all"
                i += 1
                continue
            end
            if startswith(p, "--code-coverage=")
                mode = p[(length("--code-coverage=") + 1):end]
                if mode == "user" || mode == "all" || mode == "none"
                    i += 1
                    continue
                end
            end
            push!(out, p)
            i += 1
        end
        return out
    end

    # `julia` replaces the executable when a test names another binary.
    function _julia_cmd_for(julia::AbstractString = _julia_exe())::Cmd
        cmd = Base.julia_cmd()
        exe = abspath(String(julia))
        rest = _strip_unscoped_coverage_flags(String[String(x) for x in cmd.exec[2:end]])
        return Cmd(vcat(String[exe], rest))
    end

    # `--project` for `julia -m DistSSHRun`. `TEST_PROJECT` is the process
    # startup project (`test/runtests.jl`, before any include). Do not read
    # `Base.active_project()` here: `drive!` activates the host and leaves it.
    function _cli_m_project(project::AbstractString)::String
        isdefined(@__MODULE__, :TEST_PROJECT) ||
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
        load = joinpath(@__DIR__, "install_injected_ssh.jl")
        return `$(_julia_cmd_for(julia)) --startup-file=no --project=$proj -L $load -m DistSSHRun $argv`
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
        rec = DistSSHRun.progress_latest(dir)
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
        # Default `Pkg.test()` is unit + integration. Pseudo-TTY (`script`)
        # suites live under `tty/` and need `DISTSSH_TEST_GROUP=tty` (or `all`).
        isempty(raw) && return sym !== :tty
        g = lowercase(raw)
        g == "unit" && return sym === :unit
        g == "integration" && return sym === :integration
        g == "tty" && return sym === :tty
        g == "all" && return true
        error(
            "test: invalid DISTSSH_TEST_GROUP=$(repr(raw)); want unit, integration, tty, all, or unset",
        )
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

    # A function, not a `const` inside this `if`: JETLS reports that `const` as an undefined global.
    function _distsshrun_short_skip_paths()
        return (
            "unit/DistSSHRun/options/process_env.jl", # process env snapshot tests
            "unit/DistSSHRun/core/drive/workers.jl", # long local worker spawn
            "unit/DistSSHRun/execute.jl", # long detach and polling paths
            "unit/DistSSHRun/core/setup/checks.jl", # juliaup channel fixtures
            "unit/DistSSHRun/core/setup/send_list.jl", # large send-list oracle
            "integration/cli/help.jl", # CLI help golden output
            "integration/setup/exit.jl", # setup exit-code matrix
            # Pseudo-TTY suites are `DISTSSH_TEST_GROUP=tty` (not default Pkg.test).
            # Keep them on the short-skip list for `GROUP=all` under PkgEval.
            "tty/setup/progress_tty.jl", # pseudo-TTY script suite
            "tty/drive/progress_tty.jl", # pseudo-TTY drive progress
            "integration/drive/reuse_main_isolated.jl", # isolated Main reuse drive path
            "integration/drive/execute.jl", # long-running execute integration
            "integration/drive/interrupt_grace.jl", # interrupt grace timing
            "integration/drive/pkg.jl", # Pkg-heavy drive path
            "integration/drive/log_via_script.jl", # script-driven log capture
            "integration/drive/log_via_module.jl", # module-driven log capture
            "integration/drive/pkg_develop.jl", # Pkg.develop integration
            "integration/demos/with_kit.jl", # DistSSHKit demo subprocess
            "integration/demos/without_kit.jl", # kit-less demo subprocess
        )
    end

    function _distsshrun_short_skipped(rel::AbstractString)::Bool
        _distsshrun_test_short() || return false
        return String(rel) in _distsshrun_short_skip_paths()
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

    function _runtest_short_skip_unguarded(runtests_src::AbstractString)::Vector{String}
        unguarded = String[]
        for rel in _distsshrun_short_skip_paths()
            occursin("_runtest_include(\"$rel\"", runtests_src) || continue
            occursin("_distsshrun_short_skip(\"$rel\")", runtests_src) || push!(unguarded, rel)
        end
        return unguarded
    end

    # ParallelTestRunner names: `runtests.jl` paths without `.jl`.
    function _runtest_parallel_suite_key(rel::AbstractString)::String
        return replace(String(rel), r"\.jl$" => "")
    end

    # Test files that must not share a worker batch (ports, PTYs, process-wide ENV).
    # Each path is relative to `test/` as in `runtests.jl`. Extend only after a
    # reproduced parallel collision, not with retries or sleeps.
    function _runtest_parallel_serial_paths()
        return (
            # Detached go, tagged handshake process scans, and hung-wait timing
            # races under parallel worker load (see execute.jl "wait timeout hung").
            "unit/DistSSHRun/execute.jl",
            # SIGINT/grace timing and ready files under parallel host load.
            "integration/drive/interrupt_grace.jl",
            # Local head_slots overlap wall-clock oracle (integration/go/overlap.jl).
            "integration/go/overlap.jl",
        )
    end

    function _runtest_parallel_serial_keys(runtests_src::AbstractString)
        selected = Set(_runtest_selected_files(runtests_src))
        serial = String[]
        for rel in _runtest_parallel_serial_paths()
            rel in selected || continue
            push!(serial, _runtest_parallel_suite_key(rel))
        end
        return serial
    end

    # Fail closed: `test/parallel.jl` must cover exactly the files `runtests.jl`
    # would run for the same `DISTSSH_TEST_GROUP` and short-skip env.
    function _runtest_assert_parallel_runtests_parity!(runtests_src::AbstractString)
        planned = _runtest_selected_files(runtests_src)
        expected_keys = _runtest_parallel_suite_key.(planned)
        serial = _runtest_parallel_serial_keys(runtests_src)
        unknown = setdiff(serial, expected_keys)
        !isempty(unknown) &&
            error("parallel serial list not in selected files: $(join(sort(unknown), ", "))")
        parallel_keys = filter(key -> key ∉ serial, expected_keys)
        return (;
            planned_files = planned,
            suite_keys = expected_keys,
            parallel_keys = parallel_keys,
            serial_keys = serial,
            n_files = length(planned),
        )
    end

    function _runtest_assert_planned_executed!(
            planned::AbstractVector{<:AbstractString},
            executed::AbstractVector{<:AbstractString},
        )
        planned == executed && return nothing
        only_planned = setdiff(planned, executed)
        only_executed = setdiff(executed, planned)
        io = IOBuffer()
        print(io, "test runtests.jl: planned file list does not match executed")
        print(io, " (planned=", length(planned), ", executed=", length(executed), ")")
        if !isempty(only_planned)
            print(io, "\n  planned only:")
            for rel in only_planned
                print(io, "\n    ", rel)
            end
        end
        if !isempty(only_executed)
            print(io, "\n  executed only:")
            for rel in only_executed
                print(io, "\n    ", rel)
            end
        end
        error(String(take!(io)))
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
