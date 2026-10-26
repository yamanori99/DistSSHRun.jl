using Test

# Oracle: a child project can `using DistSSHRun` from the SSH E2E vendor
# (`Project.toml` + `src/` + `lib/`) after instantiate, the same shape as
# the staged remote app. Without `lib/`, load fails on the include.
# The child depot is empty, so a DistSSHRun already in `~/.julia` cannot
# satisfy the uuid. Not real SSH.

@testset "vendored DistSSHRun includes lib" begin
    function write_app!(proj::AbstractString)
        write(
            joinpath(proj, "Project.toml"),
            """
            name = "VendorApp"
            uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            version = "0.0.1"

            [deps]
            DistSSHRun = "b568025c-2759-4ef1-8b14-17d00e2cd000"

            [sources]
            DistSSHRun = {path = "deps/DistSSHRun"}
            """,
        )
        return nothing
    end

    function run_child(depot::AbstractString, cmd::Cmd)
        env = _child_julia_env(Dict{String, String}("JULIA_DEPOT_PATH" => depot))
        return _run_subprocess(setenv(cmd, env))
    end

    _with_tempdir() do tmp
        depot = joinpath(tmp, "depot")
        mkpath(depot)
        julia = _julia_exe()

        function load_vendor(label::AbstractString; drop_lib::Bool)
            proj = joinpath(tmp, label)
            mkpath(proj)
            dest = _vendor_distsshkit!(proj)
            drop_lib && rm(joinpath(dest, "lib"); recursive = true)
            write_app!(proj)
            inst, inst_out = run_child(
                depot,
                `$julia --startup-file=no --project=$proj -e "using Pkg; Pkg.instantiate()"`,
            )
            script = joinpath(proj, "load.jl")
            write(
                script,
                """
                using DistSSHRun
                println(parentmodule(DistSSHRun.ssh_opts))
                println("PKGDIR=" * something(pkgdir(DistSSHRun), ""))
                println("PATHOF=" * something(pathof(DistSSHRun), ""))
                """,
            )
            proc, out = run_child(
                depot,
                `$julia --startup-file=no --project=$proj $script`,
            )
            return dest, inst, inst_out, proc, out
        end

        dest, inst, inst_out, proc, out = load_vendor("with"; drop_lib = false)
        _assert_proc_ok(inst, inst_out; label = "vendor instantiate")
        _assert_proc_ok(proc, out; label = "vendor load")
        @test occursin("DistSSHBase", out)
        pkg = match(r"^PKGDIR=(.*)$"m, out)
        src = match(r"^PATHOF=(.*)$"m, out)
        @test pkg !== nothing
        @test src !== nothing
        pkg_cap = pkg === nothing ? nothing : pkg.captures[1]
        src_cap = src === nothing ? nothing : src.captures[1]
        @test pkg_cap !== nothing
        @test src_cap !== nothing
        if pkg_cap !== nothing && src_cap !== nothing
            @test realpath(pkg_cap) == realpath(dest)
            @test realpath(src_cap) == realpath(joinpath(dest, "src", "DistSSHRun.jl"))
        end

        _, inst, inst_out, proc, out = load_vendor("without"; drop_lib = true)
        failed = inst.exitcode == 0 ? out : inst_out * out
        @test inst.exitcode != 0 || proc.exitcode != 0
        @test occursin("including lib/", failed)
        @test occursin("DistSSHBase.jl is missing", failed)
    end
end
