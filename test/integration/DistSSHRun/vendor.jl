using Test

# Oracle: a child julia can `using DistSSHRun` from the SSH E2E vendor
# (`Project.toml` + `src/` + `lib/`). Without `lib/`, load fails on the
# include. Not real SSH.

@testset "vendored DistSSHRun includes lib" begin
    function load_vendor(tmp, dest)
        empty_proj = joinpath(tmp, "empty")
        mkpath(empty_proj)
        write(joinpath(empty_proj, "Project.toml"), "\n")
        script = joinpath(tmp, "load.jl")
        write(
            script,
            """
            push!(LOAD_PATH, $(repr(dest)))
            using DistSSHRun
            println(parentmodule(DistSSHRun.ssh_opts))
            println(something(pkgdir(DistSSHRun), ""))
            """,
        )
        return _run_subprocess(
            setenv(
                `$(_julia_exe()) --startup-file=no --project=$empty_proj $script`,
                _child_julia_env(),
            )
        )
    end
    _with_tempdir() do tmp
        dest = _vendor_distsshkit!(tmp)
        proc, out = load_vendor(tmp, dest)
        @test proc.exitcode == 0
        @test occursin("DistSSHBase", out)
        @test occursin("DistSSHRun", out)
    end
    _with_tempdir() do tmp
        dest = _vendor_distsshkit!(tmp)
        rm(joinpath(dest, "lib"); recursive = true)
        proc, out = load_vendor(tmp, dest)
        @test proc.exitcode != 0
        @test occursin("including lib/", out)
        @test occursin("DistSSHBase.jl is missing", out)
    end
end
