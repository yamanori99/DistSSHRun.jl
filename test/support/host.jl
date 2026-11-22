if !isdefined(@__MODULE__, :_write_host_project!)

    # `Pkg.is_manifest_current` must be `true` before drive/go verification.
    # Job env that passes drive/go DistSSHRun verification (resolve + instantiate).
    function _ensure_test_job_lists_distsshrun!(proj::AbstractString)
        proj = abspath(string(proj))
        pf = joinpath(proj, "Project.toml")
        isfile(pf) || return nothing
        raw = read(pf, String)
        occursin("DistSSHRun", raw) && return nothing
        dep = "DistSSHRun = \"b568025c-2759-4ef1-8b14-17d00e2cd000\""
        if occursin("[deps]", raw)
            raw = replace(raw, "[deps]" => "[deps]\n    $dep")
        else
            raw = raw * "\n[deps]\n    $dep\n"
        end
        write(pf, raw)
        _sync_test_project_manifest!(proj)
        julia = _julia_exe()
        cmd = setenv(
            `$julia --startup-file=no --project=$proj -e "using Pkg; Pkg.instantiate()"`,
            _child_julia_env(),
        )
        proc, combined = _run_subprocess(cmd)
        _assert_proc_ok(proc, combined; label = "Pkg.instantiate ensure DistSSHRun")
        return nothing
    end

    function _write_test_job_with_distsshrun!(proj::AbstractString; name::String = "Job")
        proj = abspath(string(proj))
        write(
            joinpath(proj, "Project.toml"),
            """
            name = "$(name)"
            [deps]
            DistSSHRun = "b568025c-2759-4ef1-8b14-17d00e2cd000"
            """,
        )
        _sync_test_project_manifest!(proj)
        julia = _julia_exe()
        cmd = setenv(
            `$julia --startup-file=no --project=$proj -e "using Pkg; Pkg.instantiate()"`,
            _child_julia_env(),
        )
        proc, combined = _run_subprocess(cmd)
        _assert_proc_ok(proc, combined; label = "Pkg.instantiate test job DistSSHRun")
        return nothing
    end

    function _sync_test_project_manifest!(proj::AbstractString)
        proj = abspath(string(proj))
        isfile(joinpath(proj, "Project.toml")) ||
            isfile(joinpath(proj, "JuliaProject.toml")) ||
            return nothing
        julia = _julia_exe()
        cmd = setenv(
            `$julia --startup-file=no --project=$proj -e "using Pkg; Pkg.resolve()"`,
            _child_julia_env()
        )
        proc, combined = _run_subprocess(cmd)
        _assert_proc_ok(proc, combined; label = "Pkg.resolve test project")
        return nothing
    end

    # Detached `execute!` `-m DistSSHRun` needs DistSSHRun as the job package.
    function _write_job_with_distsshrun!(proj)
        kit = _kit_root()
        for name in ("Project.toml", "Manifest.toml", "src", "lib", "ext")
            src = joinpath(kit, name)
            ispath(src) || continue
            cp(src, joinpath(proj, name); force = true)
        end
        _sync_test_project_manifest!(proj)
        return nothing
    end

    # Write a minimal loadable host package (`Project.toml` + `src/Name.jl`).
    function _write_host_project!(
            proj,
            name::String;
            uuid::Union{Nothing, String} = nothing,
            extra_toml::String = ""
        )
        proj = abspath(string(proj))
        uuid_line = uuid === nothing ? "" : "uuid = \"$(uuid)\"\n"
        write(
            joinpath(proj, "Project.toml"),
            "name = \"$(name)\"\n$(uuid_line)version = \"0.0.1\"\n$(extra_toml)"
        )
        src = joinpath(proj, "src")
        mkpath(src)
        write(joinpath(src, "$(name).jl"), "module $(name)\nend\n")
        _sync_test_project_manifest!(proj)
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
            _child_julia_env()
        )
        proc, combined = _run_subprocess(cmd)
        _assert_proc_ok(proc, combined; label = "Pkg.develop")
        return nothing
    end

    # Log per-host HostResult details when receipt.ok is false, then return
    # receipt.ok for use inside @test.
    function _test_shipment_receipt_ok(receipt; label::AbstractString = "ShipmentReceipt")::Bool
        receipt.ok && return true
        for hr in receipt.hosts
            @error "$(label) host failure" host = hr.host ok = hr.ok message = hr.message
        end
        @error "$(label) failed" ok = receipt.ok dest = receipt.dest content_tree_hash = receipt.content_tree_hash
        return false
    end

    # Log a failed HostResult for use inside @test.
    function _test_host_result_ok(hr; label::AbstractString = "host")::Bool
        hr.ok && return true
        @error "$(label) failed" host = hr.host ok = hr.ok message = hr.message
        return false
    end

end
