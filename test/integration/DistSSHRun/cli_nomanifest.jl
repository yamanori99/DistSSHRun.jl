using Test

# A script from a checkout with no manifest exits 1 and does not develop a
# depot environment. `Pkg.test` puts the test project on `JULIA_LOAD_PATH`,
# and that project provides DistSSHRun, so these children use
# `_child_julia_env` (the same filter as the other CLI subprocesses). The
# child gets `@` and `@stdlib` only, not this process's load path. It does
# not change this process.

function _cli_chmod_writable!(root::AbstractString)
    for (dir, _, files) in walkdir(root)
        chmod(dir, filemode(dir) | 0o200)
        for name in files
            path = joinpath(dir, name)
            chmod(path, filemode(path) | 0o200)
        end
    end
    return nothing
end

# Project, `src`, and `lib` only. The root manifest stays behind.
function _cli_copy_tree!(dest::AbstractString, root::AbstractString)
    mkpath(dest)
    cp(joinpath(root, "Project.toml"), joinpath(dest, "Project.toml"))
    cp(joinpath(root, "src"), joinpath(dest, "src"))
    cp(joinpath(root, "lib"), joinpath(dest, "lib"))
    _cli_chmod_writable!(dest)
    return nothing
end

# First entry is `depot`. An empty second entry is the default depot.
# Julia splits `JULIA_DEPOT_PATH` on `;` on Windows.
function _cli_depot_first(depot::AbstractString)::String
    existing = get(ENV, "JULIA_DEPOT_PATH", "")
    depot = String(depot)
    sep = Sys.iswindows() ? ";" : ":"
    return isempty(existing) ? string(depot, sep) : string(depot, sep, existing)
end

function _cli_child(cmd::Cmd; depot::Union{Nothing, String} = nothing)::Cmd
    extra = Dict{String, String}()
    if depot !== nothing
        extra["JULIA_DEPOT_PATH"] = _cli_depot_first(depot)
    end
    return setenv(cmd, _child_julia_env(extra))
end

function _cli_assert_exit(proc, out::AbstractString, code::Int; label::AbstractString)
    if proc.exitcode != code
        println(stderr, "──── $(label) exit=$(proc.exitcode) expected $(code) ────")
        println(stderr, out)
        println(stderr, "──── end $(label) ────")
    end
    @test proc.exitcode == code
    return nothing
end

function _cli_root(tree::AbstractString)::String
    return normpath(abspath(joinpath(tree, "src", "cli", "..", "..")))
end

function _cli_no_manifest_line(tree::AbstractString)::String
    shown = _checkout_quote(_cli_root(tree))
    return "No Manifest in $(shown). Run: julia --project=$(shown) -e 'using Pkg; Pkg.instantiate()'"
end

function _cli_drive(tree::AbstractString, host::AbstractString; depot::Union{Nothing, String} = nothing)::Cmd
    drive = joinpath(tree, "src", "cli", "drive.jl")
    base = _julia_cmd_for()
    return _cli_child(
        `$base --startup-file=no --project=$host $drive --help`;
        depot = depot,
    )
end

function _cli_host!(parent::AbstractString, name::AbstractString)::String
    host = joinpath(parent, name)
    mkpath(host)
    _write_host_project!(host, "HostApp")
    return host
end

# Lock bytes for a copied tree. When this checkout has no manifest (PkgEval),
# instantiate the copy into a depot stacked first and keep that depot for the
# Usage children. Do not instantiate when a manifest is already here.
function _cli_lock!(tmp::AbstractString)::Tuple{Vector{UInt8}, Union{Nothing, String}}
    found = _checkout_manifest_file(_kit_root())
    if found !== nothing
        return read(found), nothing
    end
    tree = joinpath(tmp, "locksrc")
    depot = joinpath(tmp, "lockdepot")
    mkpath(depot)
    _cli_copy_tree!(tree, _kit_root())
    base = _julia_cmd_for()
    cmd = _cli_child(
        `$base --startup-file=no --project=$tree -e "using Pkg; Pkg.instantiate()"`;
        depot = depot,
    )
    proc, out = _run_subprocess(cmd)
    _assert_proc_ok(proc, out; label = "instantiate copied checkout")
    manifest = _checkout_manifest_file(tree)
    manifest === nothing && error("instantiate wrote no manifest under $tree")
    return read(manifest), depot
end

function _cli_line(out::AbstractString, key::AbstractString)::String
    prefix = string(key, "=")
    for line in eachline(IOBuffer(String(out)))
        startswith(line, prefix) || continue
        return String(line[(length(prefix) + 1):end])
    end
    return ""
end

# `setup.jl` includes `_checkout.jl` at top level. A project that depends on
# DistSSHRun and not on Pkg must still print `setup --help`.
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
    base = _julia_cmd_for()
    inst, inst_out = _run_subprocess(
        `$base --startup-file=no --project=$proj -e "using Pkg; Pkg.instantiate()"`,
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
    proc, out = _run_subprocess(
        addenv(
            `$base --startup-file=no --project=$proj $script`,
            "JULIA_LOAD_PATH" => proj,
            "DISTSSHKIT_CLI_SUBCOMMAND_DONE" => "0",
            "DIST_SSH_KIT_CLI_INCLUDE" => "0",
        ),
    )
    _assert_proc_ok(proc, out; label = "setup --help without Pkg on LOAD_PATH")
    @test _cli_line(out, "CODE") == "0"
    @test occursin("Usage", out)
    @test !occursin("Package Pkg not found", out)
    return nothing
end

@testset "CLI checkout without Manifest" begin
    @testset "other import errors stay" begin
        @test _checkout_hint_message(ErrorException("precompile failed")) === nothing
        @test _checkout_hint_message(MethodError(+, (1,))) === nothing
        wrapped = LoadError("child.jl", 1, MethodError(+, (1,)))
        @test _checkout_hint_message(wrapped) === nothing
        missing = ArgumentError("Package DistSSHRun not found in current path.")
        @test _checkout_hint_message(missing) === nothing
        stale = ArgumentError("Package PrecompileTools not found in current path.")
        hint = _checkout_hint_message(stale)
        @test hint isa String
        @test occursin("Pkg.instantiate()", hint)
        @test occursin("Pkg.resolve()", hint)
        @test !startswith(hint, "No Manifest in ")
    end

    _with_tempdir() do tmp
        bytes, lockdepot = _cli_lock!(tmp)

        tree = joinpath(tmp, "bare")
        depot = joinpath(tmp, "bare-depot")
        mkpath(depot)
        _cli_copy_tree!(tree, _kit_root())
        host = _cli_host!(tmp, "bare-host")
        proc, out = _run_subprocess(_cli_drive(tree, host; depot = depot))
        _cli_assert_exit(proc, out, 1; label = "no manifest")
        @test occursin(_cli_no_manifest_line(tree), out)
        @test !isdir(joinpath(depot, "environments", "distsshrun-cli"))

        ver = "Manifest-v$(VERSION.major).$(VERSION.minor).toml"
        @test ver in Base.manifest_names
        for name in ("Manifest.toml", ver)
            locked = joinpath(tmp, "locked-$(name)")
            _cli_copy_tree!(locked, _kit_root())
            write(joinpath(locked, name), bytes)
            locked_host = _cli_host!(tmp, "host-$(name)")
            help, help_out = _run_subprocess(
                _cli_drive(locked, locked_host; depot = lockdepot),
            )
            _assert_proc_ok(help, help_out; label = "manifest $(name)")
            @test occursin("Usage", help_out)
            @test !occursin("No Manifest in ", help_out)
        end

        inst = joinpath(tmp, "inst-depot")
        installed = joinpath(inst, "packages", "DistSSHRun", "cli0")
        _cli_copy_tree!(installed, _kit_root())
        inst_host = _cli_host!(tmp, "inst-host")
        denied, denied_out = _run_subprocess(
            _cli_drive(installed, inst_host; depot = inst),
        )
        _cli_assert_exit(denied, denied_out, 1; label = "depot tree")
        @test !occursin("No Manifest in ", denied_out)
        @test !occursin("Pkg.instantiate()", denied_out)
        @test occursin("Package DistSSHRun not found in current path", denied_out)

        wrapped_tree = joinpath(tmp, "wrap-tree")
        _cli_copy_tree!(wrapped_tree, _kit_root())
        wrap_host = _cli_host!(tmp, "wrap-host")
        drive = joinpath(wrapped_tree, "src", "cli", "drive.jl")
        wrapper = joinpath(tmp, "wrap.jl")
        write(
            wrapper,
            """
            try
                include($(repr(drive)))
                println("NOT_THROWN")
            catch err
                println("CAUGHT")
                shown = err
                seen = 0
                while shown isa LoadError && seen < 8
                    shown = shown.error
                    seen += 1
                end
                msg = shown isa ErrorException ? shown.msg : sprint(showerror, err)
                println(msg)
            end
            """,
        )
        base = _julia_cmd_for()
        included, included_out = _run_subprocess(
            _cli_child(`$base --startup-file=no --project=$wrap_host $wrapper`),
        )
        _assert_proc_ok(included, included_out; label = "include does not exit")
        @test occursin("CAUGHT", included_out)
        @test !occursin("NOT_THROWN", included_out)
        @test occursin(_cli_no_manifest_line(wrapped_tree), included_out)

        mod, mod_out = _run_subprocess(
            addenv(
                _kit_cli_cmd(["drive", "--help"]),
                "DISTSSHKIT_CLI_SUBCOMMAND_DONE" => "0",
            ),
        )
        _assert_proc_ok(mod, mod_out; label = "julia -m DistSSHRun drive --help")
        @test occursin("Usage", mod_out)

        _checkout_pkg_hidden_check(tmp)
    end
end
