using Test

# Oracle: a checkout with no Manifest still loads through the CLI.
# The child depot is empty except for the default depot appended after `:`,
# so this is the PkgEval shape (package tree has no Manifest, active project
# is a different env). The developed environment stays in the child depot.

# Same slug as `_checkout_load_env`: the root `_include_checkout_run` builds
# (`src/cli/../../`), then the Project.toml bytes. That root keeps a trailing
# separator, so `abspath(tree)` is a different hash.
function _nomanifest_env(depot::AbstractString, tree::AbstractString)::String
    root = normpath(abspath(joinpath(tree, "src", "cli", "..", "..")))
    toml = read(joinpath(tree, "Project.toml"), String)
    slug = string(hash(root * "\n" * toml); base = 16)
    return joinpath(depot, "environments", "distsshrun-cli", slug)
end

# Corrupt Manifest, no marker: in-place develop fails and the directory is rebuilt.
function _nomanifest_plant_half!(env::AbstractString)
    mkpath(env)
    write(joinpath(env, "Manifest.toml"), "half-ready\n")
    write(joinpath(env, "stale.txt"), "stale\n")
    return nothing
end

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
    half = _nomanifest_env(depot, tree)
    _nomanifest_plant_half!(half)
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
    @test normpath(env) == normpath(half)
    @test !isfile(joinpath(half, "stale.txt"))
    @test isfile(joinpath(half, "distsshrun-ready"))
    @test read(joinpath(half, "Manifest.toml"), String) != "half-ready\n"
    @test !isfile(joinpath(tree, "Manifest.toml"))
    rm(joinpath(half, "distsshrun-ready"); force = true)
    write(joinpath(half, "keep.txt"), "keep\n")
    again, again_out = _nomanifest_run(
        depot,
        `$julia --startup-file=no --project=$host $script`,
    )
    _assert_proc_ok(again, again_out; label = "checkout reuse")
    @test _nomanifest_line(again_out, "ACTIVE_SAME") == "true"
    @test isfile(joinpath(half, "keep.txt"))
    @test isfile(joinpath(half, "distsshrun-ready"))
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

# `Pkg.test` sets `JULIA_LOAD_PATH` to the test project and does not append
# `@stdlib`. DistSSHKit's test project does not depend on Pkg. `setup --help`
# includes `_checkout.jl` and must still run.
function _checkout_pkg_hidden!(proj::AbstractString, root::AbstractString)
    mkpath(proj)
    write(
        joinpath(proj, "Project.toml"),
        """
        name = "KitLike"
        uuid = "22222222-2222-4222-8222-222222222222"
        version = "0.0.1"

        [deps]
        DistSSHRun = "b568025c-2759-4ef1-8b14-17d00e2cd000"

        [sources]
        DistSSHRun = {path = "$(root)"}
        """,
    )
    return nothing
end

function _checkout_pkg_hidden_check(tmp::AbstractString)
    proj = joinpath(tmp, "kitlike")
    _checkout_pkg_hidden!(proj, _kit_root())
    julia = _julia_exe()
    inst, inst_out = _run_subprocess(
        `$julia --startup-file=no --project=$proj -e "using Pkg; Pkg.instantiate()"`,
    )
    _assert_proc_ok(inst, inst_out; label = "kitlike instantiate")
    script = joinpath(tmp, "setup_help.jl")
    write(
        script,
        """
        using DistSSHRun
        code = DistSSHRun.main(["setup", "--help"])
        println("CODE=" * string(Int(code)))
        """,
    )
    env = _child_julia_env(Dict{String, String}("JULIA_LOAD_PATH" => proj))
    proc, out = _run_subprocess(
        setenv(`$julia --startup-file=no --project=$proj $script`, env),
    )
    _assert_proc_ok(proc, out; label = "setup --help without Pkg on LOAD_PATH")
    @test _nomanifest_line(out, "CODE") == "0"
    @test occursin("Usage", out)
    @test !occursin("Package Pkg not found", out)
    return nothing
end

@testset "CLI checkout without Manifest" begin
    _with_tempdir() do tmp
        _nomanifest_check(tmp)
        _checkout_pkg_hidden_check(tmp)
    end
end
