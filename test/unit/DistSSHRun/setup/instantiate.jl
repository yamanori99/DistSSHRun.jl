using Test

@testset "remote instantiate" begin
    expr = DistSSHRun._instantiate_remote_e()
    @test occursin(
        "Pkg.instantiate(; manifest=true, update_registry=false, julia_version_strict=true)",
        expr,
    )
    @test occursin("Pkg.is_manifest_current(", expr)
    @test occursin("Pkg.Registry.reachable_registries()", expr)
    @test occursin("help setup", expr)
    @test !occursin("--help", expr)
    @test !occursin("JULIA_PKG_OFFLINE", expr)

    function _child_env(depot::AbstractString)
        env = Dict{String, String}(k => v for (k, v) in ENV)
        env["JULIA_DEPOT_PATH"] = depot
        delete!(env, "JULIA_PKG_OFFLINE")
        return env
    end

    function _run_instantiate_e(project::AbstractString, depot::AbstractString)
        cmd = setenv(
            Cmd(
                [
                    _julia_exe(),
                    "--startup-file=no",
                    "--project=$project",
                    "-e",
                    DistSSHRun._instantiate_remote_e(),
                ]
            ),
            _child_env(depot),
        )
        out = IOBuffer()
        err = IOBuffer()
        proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err); wait = true)
        return proc.exitcode, String(take!(out)), String(take!(err))
    end

    function _prepare_depot!(depot::AbstractString)
        minor = "$(VERSION.major).$(VERSION.minor)"
        mkpath(joinpath(depot, "environments", "v$minor"))
        reg = joinpath(depot, "registries", "Fake")
        mkpath(reg)
        write(
            joinpath(reg, "Registry.toml"),
            """
            name = "Fake"
            uuid = "d8e8e8e8-1111-4111-8111-111111111111"
            repo = "https://example.invalid/Fake"
            description = "test registry"

            [packages]
            """,
        )
        compiled = joinpath(first(DEPOT_PATH), "compiled")
        if isdir(compiled)
            cp(compiled, joinpath(depot, "compiled"))
        end
        return nothing
    end

    function _seed_project!(project::AbstractString, depot::AbstractString)
        mkpath(project)
        write(
            joinpath(project, "Project.toml"),
            """
            name = "Job"
            uuid = "c0ffee00-1111-4111-8111-111111111111"
            version = "0.1.0"
            """,
        )
        mkpath(joinpath(project, "src"))
        write(joinpath(project, "src", "Job.jl"), "module Job\nend\n")
        cmd = setenv(
            Cmd(
                [
                    _julia_exe(),
                    "--startup-file=no",
                    "--project=$project",
                    "-e",
                    "using Pkg; Pkg.instantiate(; update_registry=false)",
                ]
            ),
            _child_env(depot),
        )
        err = IOBuffer()
        proc = run(pipeline(ignorestatus(cmd); stdout = devnull, stderr = err); wait = true)
        proc.exitcode == 0 || error("seed instantiate failed:\n$(String(take!(err)))")
        isfile(joinpath(project, "Manifest.toml")) || error("seed wrote no Manifest.toml")
        return nothing
    end

    function _depot_without_registries(src::AbstractString, dst::AbstractString)
        minor = "$(VERSION.major).$(VERSION.minor)"
        mkpath(joinpath(dst, "environments", "v$minor"))
        compiled = joinpath(src, "compiled")
        isdir(compiled) && cp(compiled, joinpath(dst, "compiled"))
        return dst
    end

    @testset "remote command" begin
        _with_tempdir() do state
            logp = joinpath(state, "ssh.log")
            _with_tempdir() do proj
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
                write(joinpath(proj, "Manifest.toml"), "# lock\n")
                withenv(
                    merge(
                        _fake_setup_remote_env(state),
                        Dict("DISTSSHKIT_TEST_SSH_LOG" => logp),
                    )...,
                ) do
                    inst = DistSSHRun.instantiate_remotes(
                        ["h1"], "/bin/echo", "~/App.jl", proj,
                    )
                    @test inst.failed == 0 && inst.succeeded == 1
                    tested = DistSSHRun.runtest_remotes(
                        ["h1"], "/bin/echo", "~/App.jl", proj,
                    )
                    @test tested.failed == 0 && tested.succeeded == 1
                end
            end
            script = read(logp, String)
            @test occursin(
                "Pkg.instantiate(; manifest=true, update_registry=false, julia_version_strict=true)",
                script,
            )
            @test occursin("help setup", script)
            @test !occursin("--help", script)
            @test !occursin("JULIA_PKG_OFFLINE", script)
            @test occursin("JULIA_PKG_USE_CLI_GIT=true", script)
            @test occursin("-e 'using Pkg; Pkg.test()'", script)
        end
    end

    @testset "worker program" begin
        _with_tempdir() do root
            depot = joinpath(root, "depot")
            _prepare_depot!(depot)
            base = joinpath(root, "base")
            _seed_project!(base, depot)
            lock = read(joinpath(base, "Manifest.toml"), String)
            @test occursin("project_hash", lock)
            @test occursin("julia_version", lock)

            @testset "happy path" begin
                proj = joinpath(root, "happy")
                cp(base, proj)
                before = read(joinpath(proj, "Manifest.toml"))
                code, out, err = _run_instantiate_e(proj, depot)
                shown = out * err
                @test code == 0
                @test !occursin("ERROR:", shown)
                @test !occursin("help setup", shown)
                @test !occursin("Resolving", shown)
                @test !occursin("Updating", shown)
                @test read(joinpath(proj, "Manifest.toml")) == before
            end

            @testset "no reachable registries" begin
                proj = joinpath(root, "noreg")
                cp(base, proj)
                bare = _depot_without_registries(depot, joinpath(root, "bare-depot"))
                before = read(joinpath(proj, "Manifest.toml"))
                code, _, err = _run_instantiate_e(proj, bare)
                @test code != 0
                @test occursin("no reachable package registries. See help setup.", err)
                @test !occursin("--help", err)
                @test read(joinpath(proj, "Manifest.toml")) == before
            end

            @testset "stale project_hash" begin
                proj = joinpath(root, "stale")
                cp(base, proj)
                open(joinpath(proj, "Project.toml"), "a") do io
                    println(io, "\n[deps]")
                    println(io, "Example = \"7876af07-990d-54b4-ab0e-23690620f79a\"")
                end
                before = read(joinpath(proj, "Manifest.toml"))
                code, _, err = _run_instantiate_e(proj, depot)
                @test code != 0
                @test occursin("Manifest is not current with the project. See help setup.", err)
                @test !occursin("--help", err)
                @test read(joinpath(proj, "Manifest.toml")) == before
            end

            @testset "manifest without project_hash" begin
                proj = joinpath(root, "nohash")
                cp(base, proj)
                path = joinpath(proj, "Manifest.toml")
                text = read(path, String)
                stripped = replace(text, r"^project_hash = .*\n"m => "")
                @test stripped != text
                write(path, stripped)
                code, _, err = _run_instantiate_e(proj, depot)
                @test code != 0
                @test occursin("Manifest is not current with the project. See help setup.", err)
                @test !occursin("--help", err)
                @test !occursin("project_hash", read(path, String))
            end

            @testset "missing julia_version" begin
                proj = joinpath(root, "nojulia")
                cp(base, proj)
                path = joinpath(proj, "Manifest.toml")
                text = read(path, String)
                stripped = replace(text, r"^julia_version = .*\n"m => "")
                @test stripped != text
                @test occursin("project_hash", stripped)
                write(path, stripped)
                code, _, err = _run_instantiate_e(proj, depot)
                @test code != 0
                @test occursin("Manifest julia_version is missing. See help setup.", err)
                @test !occursin("--help", err)
                @test !occursin(r"^julia_version ="m, read(path, String))
            end

            @testset "julia minor mismatch" begin
                proj = joinpath(root, "minor")
                cp(base, proj)
                path = joinpath(proj, "Manifest.toml")
                text = read(path, String)
                bumped = replace(text, r"^julia_version = \".*\""m => "julia_version = \"1.10.9\"")
                @test bumped != text
                write(path, bumped)
                before = read(path)
                code, _, err = _run_instantiate_e(proj, depot)
                @test code != 0
                @test occursin("Manifest julia_version 1.10.9 does not match this Julia", err)
                @test occursin("See help setup.", err)
                @test !occursin("--help", err)
                @test read(path) == before
            end
        end
    end
end
