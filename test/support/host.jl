if !isdefined(Main, :_write_host_project!)

    # Detached `execute!` `-m DistSSHRun` needs DistSSHRun as the job package.
    function _write_job_with_distsshrun!(proj)
        kit = _kit_root()
        for name in ("Project.toml", "Manifest.toml", "src", "lib", "ext")
            src = joinpath(kit, name)
            ispath(src) || continue
            cp(src, joinpath(proj, name); force = true)
        end
        return nothing
    end

    # Write a minimal loadable host package (`Project.toml` + `src/Name.jl`).
    function _write_host_project!(
            proj,
            name::String;
            uuid::Union{Nothing, String} = nothing,
            extra_toml::String = "",
        )
        proj = abspath(string(proj))
        uuid_line = uuid === nothing ? "" : "uuid = \"$(uuid)\"\n"
        write(
            joinpath(proj, "Project.toml"),
            "name = \"$(name)\"\n$(uuid_line)version = \"0.0.1\"\n$(extra_toml)",
        )
        write(joinpath(proj, "Manifest.toml"), "# lock\n")
        src = joinpath(proj, "src")
        mkpath(src)
        write(joinpath(src, "$(name).jl"), "module $(name)\nend\n")
        return nothing
    end

    function _git_init_min!(proj)
        git = Sys.which("git")
        git === nothing && return nothing
        isdir(joinpath(proj, ".git")) && return nothing
        run(`$git -C $proj init --quiet`)
        run(`$git -C $proj config user.email t@t.t`)
        run(`$git -C $proj config user.name t`)
        run(`$git -C $proj add -A`)
        run(`$git -C $proj commit --quiet -m init`)
        return nothing
    end

    function _mktemp_host(f::Function)
        return _with_tempdir() do path
            f(path)
        end
    end

    function _develop_kit!(host_project::String; kit_root::String = _kit_root(), julia::String = _julia_exe())
        cmd = setenv(
            `$julia --project=$host_project -e "using Pkg; Pkg.develop(path=$(repr(kit_root)))"`,
            _child_julia_env(),
        )
        proc, combined = _run_subprocess(cmd)
        _assert_proc_ok(proc, combined; label = "Pkg.develop")
        return nothing
    end

end
