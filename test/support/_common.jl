# Loaded first from support.jl (same role as DistSSHRun/drive/runtime/_common.jl).
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

    # Kit root when that tree has a manifest. Otherwise the active project
    # (`Pkg.test`'s env), which already depends on DistSSHRun.
    function _cli_m_project(project::AbstractString)::String
        if _checkout_manifest_file(String(project)) !== nothing
            return String(project)
        end
        active = Base.active_project()
        active === nothing && return String(project)
        return String(active)
    end

    # Kit CLI as a child `julia -m DistSSHRun`.
    function _kit_cli_cmd(
            args::AbstractVector{<:AbstractString};
            julia::AbstractString = _julia_exe(),
            project::AbstractString = _kit_root(),
        )::Cmd
        proj = _cli_m_project(String(project))
        argv = String[String(a) for a in args]
        return `$(_julia_cmd_for(julia)) --startup-file=no --project=$proj -m DistSSHRun $argv`
    end

    # Temp go/drive/size/setup hosts file: comment, `child:host-a`, `child:host-b:4`.
    function _sample_hosts_file()::String
        path, io = mktemp()
        try
            write(io, "# lab hosts (comments and host:N lines)\nchild:host-a:1\nchild:host-b:4\n")
            close(io)
        catch
            close(io)
            rm(path; force = true)
            rethrow()
        end
        return path
    end

    const _sample_setup_hosts_file = _sample_hosts_file

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

    function _distsshrun_short_skip(rel::AbstractString)::Bool
        _distsshrun_test_short() || return false
        skipped = (
            "unit/DistSSHRun/drive/workers.jl",
            "unit/DistSSHRun/execute.jl",
            "unit/DistSSHRun/setup/checks.jl",
            "unit/DistSSHRun/setup/send_list.jl",
            "integration/cli/help.jl",
            "integration/setup/exit.jl",
            "integration/drive/execute.jl",
            "integration/drive/interrupt_grace.jl",
            "integration/drive/pkg.jl",
            "integration/drive/log_via_script.jl",
            "integration/drive/log_via_module.jl",
            "integration/drive/pkg_develop.jl",
            "integration/demos/with_kit.jl",
            "integration/demos/without_kit.jl",
        )
        String(rel) in skipped || return false
        println("  short: skip $rel")
        flush(stdout)
        return true
    end

end
