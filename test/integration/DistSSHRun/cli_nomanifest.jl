using Test

# Oracle: a checkout with no Manifest still loads through the CLI.
# The child depot is empty except for the default depot appended after `:`,
# so this is the PkgEval shape (package tree has no Manifest, active project
# is a different env). The developed environment stays in the child depot.

function _nomanifest_copy!(dest::AbstractString, root::AbstractString)
    mkpath(dest)
    cp(joinpath(root, "Project.toml"), joinpath(dest, "Project.toml"))
    cp(joinpath(root, "src"), joinpath(dest, "src"))
    cp(joinpath(root, "lib"), joinpath(dest, "lib"))
    return nothing
end

function _nomanifest_run(depot::AbstractString, cmd::Cmd)
    env = _child_julia_env(Dict{String, String}("JULIA_DEPOT_PATH" => string(depot, ":")))
    return _run_subprocess(setenv(cmd, env))
end

function _nomanifest_line(out::AbstractString, key::AbstractString)::String
    prefix = string(key, "=")
    for line in eachline(IOBuffer(String(out)))
        startswith(line, prefix) || continue
        return String(line[(length(prefix) + 1):end])
    end
    return ""
end

function _nomanifest_check(tmp::AbstractString)
    tree = joinpath(tmp, "tree")
    host = joinpath(tmp, "host")
    depot = joinpath(tmp, "depot")
    mkpath(depot)
    mkpath(host)
    _nomanifest_copy!(tree, _kit_root())
    _write_host_project!(host, "HostApp")
    julia = _julia_exe()
    script = joinpath(tmp, "load.jl")
    write(
        script,
        """
        include($(repr(joinpath(tree, "src", "cli", "_checkout.jl"))))
        before = something(Base.active_project(), "")
        _include_checkout_run()
        import DistSSHRun
        after = something(Base.active_project(), "")
        println("ACTIVE_SAME=" * string(before == after))
        println("LOAD0=" * string(LOAD_PATH[1]))
        println("PATHOF=" * something(pathof(DistSSHRun), ""))
        println("TREE_MANIFEST=" * string(isfile($(repr(joinpath(tree, "Manifest.toml"))))))
        """,
    )
    proc, out = _nomanifest_run(
        depot,
        `$julia --startup-file=no --project=$host $script`,
    )
    _assert_proc_ok(proc, out; label = "checkout load")
    @test _nomanifest_line(out, "ACTIVE_SAME") == "true"
    @test _nomanifest_line(out, "TREE_MANIFEST") == "false"
    loaded = _nomanifest_line(out, "PATHOF")
    @test !isempty(loaded)
    if !isempty(loaded)
        @test realpath(loaded) == realpath(joinpath(tree, "src", "DistSSHRun.jl"))
    end
    env = _nomanifest_line(out, "LOAD0")
    @test startswith(env, depot)
    @test !isfile(joinpath(tree, "Manifest.toml"))
    drive = joinpath(tree, "src", "cli", "drive.jl")
    help, help_out = _nomanifest_run(
        depot,
        `$julia --startup-file=no --project=$host $drive --help`,
    )
    _assert_proc_ok(help, help_out; label = "drive --help")
    @test occursin("Usage", help_out)
    @test !occursin("does not seem to be installed", help_out)
    mod, mod_out = _nomanifest_run(
        depot,
        `$julia --startup-file=no --project=$env -m DistSSHRun drive --help`,
    )
    _assert_proc_ok(mod, mod_out; label = "-m drive --help")
    @test occursin("Usage", mod_out)
    @test !occursin("does not seem to be installed", mod_out)
    return nothing
end

@testset "CLI checkout without Manifest" begin
    _with_tempdir() do tmp
        _nomanifest_check(tmp)
    end
end
