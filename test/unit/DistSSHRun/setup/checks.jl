using Test
using Pkg

@testset "setup checks" begin
    @test DistSSHRun.julia_version_mismatch_kind(v"1.12.6", v"1.12.6") == :none
    @test DistSSHRun.julia_version_mismatch_kind(v"1.12.6", v"1.12.9") == :patch
    @test DistSSHRun.julia_version_mismatch_kind(v"1.12.6", v"1.11.6") == :minor
    @test DistSSHRun.julia_version_mismatch_kind(v"1.12.6", v"2.0.6") == :minor
    # --check fails on :minor unless --ignore-julia-version (see check_prerequisites).
    @test DistSSHRun.julia_version_mismatch_kind(VERSION, VersionNumber(VERSION.major, VERSION.minor + 1, 0)) ==
        :minor

    @test DistSSHRun.juliaup_channel(v"1.12.6") == "1.12"
    @test DistSSHRun.juliaup_channel(VERSION) == "$(VERSION.major).$(VERSION.minor)"
    @test DistSSHRun.remote_juliaup_candidates("Darwin") == [
        raw"$HOME/.juliaup/bin/juliaup",
        "/opt/homebrew/bin/juliaup",
        "/usr/local/bin/juliaup",
    ]
    @test DistSSHRun.remote_juliaup_candidates("Linux") == [raw"$HOME/.juliaup/bin/juliaup"]
    sh = DistSSHRun._juliaup_align_remote_sh("1.12")
    @test occursin(raw"$HOME/.juliaup/bin/juliaup", sh)
    @test occursin("/opt/homebrew/bin/juliaup", sh)
    @test occursin(" add ", sh) || occursin("add '", sh)
    @test occursin("update", sh) && occursin("default", sh)
    @test occursin("echo already", sh)
    @test occursin("\$1==\"*\"", sh)
    up_sh = DistSSHRun._juliaup_update_remote_sh()
    @test occursin(raw"$HOME/.juliaup/bin/juliaup", up_sh)
    @test occursin("\"\$JU\" update", up_sh)
    @test !occursin("echo already", up_sh)
    @test !occursin("default", up_sh)
    st = """
    Default  Channel  Version
    -------------------------------------------------------------------------
         *  1.13     1.13.2+0.aarch64.apple.darwin14
          1.12     1.12.7+0.aarch64.apple.darwin14
    """
    @test DistSSHRun._juliaup_default_channel_from_status(st) == "1.13"
    @test DistSSHRun._juliaup_default_channel_from_status("no default here") === nothing
    # Channel must not enter remote diagnostics unquoted (shell metacharacters).
    sh_meta = DistSSHRun._juliaup_align_remote_sh("1.12\$(id)")
    @test occursin("'1.12\$(id)'", sh_meta)
    @test !occursin("juliaup add 1.12\$(id) failed", sh_meta)
    DistSSHRun.print_juliaup_align_fix!("user@host"; kind = :missing, channel = "1.12")
    DistSSHRun.print_juliaup_align_fix!("user@host"; kind = :mismatch, channel = "1.12")
    @test DistSSHRun.juliaup_parent_behind_channel(v"1.12.6", v"1.12.9")
    @test !DistSSHRun.juliaup_parent_behind_channel(v"1.12.9", v"1.12.6")
    @test !DistSSHRun.juliaup_parent_behind_channel(v"1.12.6", v"1.12.6")
    @test !DistSSHRun.juliaup_parent_behind_channel(v"1.12.6", v"1.11.9")
    @test DistSSHRun.print_juliaup_parent_patch_note!(
        v"1.12.9"; local_version = v"1.12.6", channel = "1.12",
    )
    @test !DistSSHRun.print_juliaup_parent_patch_note!(
        v"1.12.6"; local_version = v"1.12.6", channel = "1.12",
    )
    tip_out, _ = with_kit_verbosity(:verbose) do
        _capture_stdio() do _, _
            DistSSHRun.print_juliaup_parent_patch_note!(
                v"1.12.9"; local_version = v"1.12.6", channel = "1.12",
            )
        end
    end
    @test occursin("setup --juliaup parent", tip_out)
    @test occursin(".juliaup", DistSSHRun.local_juliaup_candidates()[1])
    @test DistSSHRun.find_local_juliaup(String[]) === nothing
    mktempdir() do d
        ju = joinpath(d, "juliaup")
        jl = joinpath(d, "julia")
        write(
            ju, """
            #!/bin/sh
            case "\$1" in
              add|update|default)
                echo "Checking for new Julia versions" >&2
                echo "'1.13' is already installed."
                exit 0
                ;;
              status) echo "1.12"; exit 0 ;;
              *) exit 1 ;;
            esac
            """
        )
        write(
            jl, """
            #!/bin/sh
            echo "julia version $(VERSION.major).$(VERSION.minor).$(VERSION.patch)"
            """
        )
        chmod(ju, 0o755)
        chmod(jl, 0o755)
        withenv("DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
            @test DistSSHRun.find_local_juliaup() == ju
            ch = "$(VERSION.major).$(VERSION.minor)"
            captured, r = _capture_stdio() do _, _
                DistSSHRun._juliaup_align_local!(ch)
            end
            @test r.changed
            @test DistSSHRun.julia_version_mismatch_kind(VERSION, r.ver) != :minor
            @test !occursin("Checking for new Julia versions", captured)
            @test !occursin("already installed", captured)
        end
    end

    mktempdir() do d
        ju = joinpath(d, "juliaup")
        jl = joinpath(d, "julia")
        ch = "$(VERSION.major).$(VERSION.minor)"
        write(
            ju,
            """
            #!/bin/sh
            case "\$1" in
              status) echo '       *  $ch     julia version'; exit 0 ;;
              add|update|default) echo "unexpected \$1" >&2; exit 1 ;;
              *) exit 1 ;;
            esac
            """,
        )
        write(
            jl,
            """
            #!/bin/sh
            echo "julia version $(VERSION.major).$(VERSION.minor).$(VERSION.patch)"
            """,
        )
        chmod(ju, 0o755)
        chmod(jl, 0o755)
        withenv("DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
            r = DistSSHRun._juliaup_align_local!(ch)
            @test !r.changed
            @test DistSSHRun.julia_version_mismatch_kind(VERSION, r.ver) != :minor
            out, _ = with_kit_verbosity(:progress) do
                _capture_stdio() do _, _
                    DistSSHRun.juliaup_align_remotes(["parent"]; confirm = false)
                end
            end
            @test occursin("parent: already on $ch", out)
        end
    end

    mktempdir() do d
        ju = joinpath(d, "juliaup")
        jl = joinpath(d, "julia")
        write(
            ju, """
            #!/bin/sh
            case "\$1" in
              add) echo "network failed"; exit 1 ;;
              status) echo "empty"; exit 0 ;;
              *) exit 1 ;;
            esac
            """
        )
        write(
            jl, """
            #!/bin/sh
            echo "julia version $(VERSION.major).$(VERSION.minor).$(VERSION.patch)"
            """
        )
        chmod(ju, 0o755)
        chmod(jl, 0o755)
        withenv("DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
            err = try
                DistSSHRun._juliaup_align_local!("$(VERSION.major).$(VERSION.minor)")
                nothing
            catch e
                sprint(showerror, e)
            end
            @test err !== nothing
            @test occursin("network failed", err)
        end
    end

    @test begin
        t = withenv("PATH" => "/nonexistent-distsshkit-path") do
            redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    DistSSHRun._report_local_host_tools!()
                end
            end
        end
        !t.ssh && !t.rsync && !t.git
    end

    expr = DistSSHRun._project_deps_probe_expr()
    @test occursin("locate_package", expr)
    @test occursin("not instantiated", expr)

    _with_tempdir() do dir
        @test DistSSHRun.probe_project_deps(dir) == "Project.toml not found"
        write(joinpath(dir, "Project.toml"), "[deps]\n")
        @test occursin("Manifest.toml not found", DistSSHRun.probe_project_deps(dir))
    end

    _with_tempdir() do dir
        write(joinpath(dir, "Project.toml"), "[deps]\n")
        Pkg.activate(dir) do
            Pkg.instantiate(; io = devnull)
        end
        @test DistSSHRun.probe_project_deps(dir) === nothing
    end

    @testset "check_prerequisites git commit missing is a warning" begin
        _with_tempdir() do dir
            write(joinpath(dir, "Project.toml"), "[deps]\n")
            out, result = with_kit_verbosity(:verbose) do
                _capture_stdio() do _, _
                    DistSSHRun.check_prerequisites(
                        String[], "auto", "~/App.jl", dir;
                        require_clean_git = false,
                    )
                end
            end
            @test occursin("Could not get local git commit", out)
            @test occursin("Skip hash check", out)
            @test !occursin("✗ Could not get local git commit", out)
            Sys.which("ssh") === nothing || @test result.ok
        end
    end

    @testset "check_prerequisites dirty tree" begin
        Sys.which("git") === nothing && return
        _with_tempdir() do dir
            write(joinpath(dir, "Project.toml"), "[deps]\n")
            run(pipeline(`git -C $dir init -q`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $dir config user.email "test@example.com"`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $dir config user.name "Test"`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $dir add Project.toml`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $dir commit -q -m init`; stdout = devnull, stderr = devnull))
            write(joinpath(dir, "dirty.txt"), "x\n")

            out_warn, result_warn = with_kit_verbosity(:verbose) do
                _capture_stdio() do _, _
                    DistSSHRun.check_prerequisites(
                        String[], "auto", "~/App.jl", dir;
                        require_clean_git = false,
                    )
                end
            end
            @test occursin("Git has uncommitted changes", out_warn)
            @test !occursin("✗ Git has uncommitted changes", out_warn)
            Sys.which("ssh") === nothing || @test result_warn.ok

            out_fail, result_fail = with_kit_verbosity(:verbose) do
                _capture_stdio() do _, _
                    DistSSHRun.check_prerequisites(
                        String[], "auto", "~/App.jl", dir;
                        require_clean_git = true,
                    )
                end
            end
            @test !result_fail.ok
            @test occursin("Git has uncommitted changes", out_fail)
        end
    end

    @testset "resolve_pkg_env follows Base.active_manifest" begin
        _with_tempdir() do root
            lab = joinpath(root, "lab")
            member = joinpath(lab, "experiments", "run1")
            mkpath(member)
            write(
                joinpath(lab, "Project.toml"), """
                name = "Lab"
                [workspace]
                projects = ["experiments/run1"]
                """
            )
            write(joinpath(lab, "Manifest.toml"), "# lock\n")
            write(
                joinpath(member, "Project.toml"), """
                name = "Run1"
                [deps]
                """
            )
            env = DistSSHRun.resolve_pkg_env(member)
            @test env.project_dir == DistSSHRun.canonical_local_path(member)
            @test env.env_dir == DistSSHRun.canonical_local_path(lab)
            @test env.manifest == DistSSHRun.canonical_local_path(joinpath(lab, "Manifest.toml"))
            @test DistSSHRun.julia_project_rel(env) == joinpath("experiments", "run1")
            shipped = DistSSHRun.ensure_manifest_ships!(member)
            @test shipped.env_dir == env.env_dir
            withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => nothing) do
                deploy = DistSSHRun.remote_deploy_root(member)
                julia_remote = DistSSHRun.resolve_remote_project_root(member)
                @test deploy == joinpath("~", basename(dirname(lab)), "lab")
                @test julia_remote == joinpath(deploy, "experiments", "run1")
                if Sys.which("git") !== nothing
                    run(pipeline(`git -C $lab init -q`; stdout = devnull, stderr = devnull))
                    @test DistSSHRun.remote_git_clone_dest(member) == deploy
                end
            end

            solo = joinpath(root, "solo")
            mkpath(solo)
            write(joinpath(solo, "Project.toml"), "name = \"Solo\"\n[deps]\n")
            bare = DistSSHRun.resolve_pkg_env(solo)
            @test bare.manifest === nothing
            @test bare.env_dir == bare.project_dir
            @test DistSSHRun.julia_project_rel(bare) == "."

            ver = joinpath(root, "ver")
            mkpath(ver)
            write(joinpath(ver, "Project.toml"), "name = \"Ver\"\n[deps]\n")
            write(joinpath(ver, "Manifest-v$(VERSION.major).$(VERSION.minor).toml"), "# v\n")
            versioned = DistSSHRun.resolve_pkg_env(ver)
            @test versioned.manifest == DistSSHRun.canonical_local_path(
                joinpath(ver, "Manifest-v$(VERSION.major).$(VERSION.minor).toml"),
            )
            @test versioned.env_dir == versioned.project_dir

            elsewhere = joinpath(root, "elsewhere")
            mkpath(elsewhere)
            outside_manifest = joinpath(root, "side", "Manifest.toml")
            mkpath(dirname(outside_manifest))
            write(outside_manifest, "# x\n")
            write(
                joinpath(elsewhere, "Project.toml"),
                "name = \"Out\"\nmanifest = \"$(outside_manifest)\"\n",
            )
            outside = DistSSHRun.resolve_pkg_env(elsewhere)
            @test outside.manifest == DistSSHRun.canonical_local_path(outside_manifest)
            @test_throws ArgumentError DistSSHRun.ensure_manifest_ships!(elsewhere)

            linked = joinpath(root, "linked")
            mkpath(linked)
            write(joinpath(linked, "Project.toml"), "name = \"Linked\"\n[deps]\n")
            write(joinpath(linked, "Manifest-real.toml"), "# in tree\n")
            symlink("Manifest-real.toml", joinpath(linked, "Manifest.toml"))
            linked_env = DistSSHRun.ensure_manifest_ships!(linked)
            @test linked_env.env_dir == DistSSHRun.canonical_local_path(linked)
            rm(joinpath(linked, "Manifest.toml"))
            symlink(outside_manifest, joinpath(linked, "Manifest.toml"))
            @test_throws ArgumentError DistSSHRun.ensure_manifest_ships!(linked)

            if Sys.which("git") !== nothing
                repo = joinpath(root, "repo")
                mkpath(repo)
                write(joinpath(repo, "Project.toml"), "name = \"Repo\"\nmanifest = \"$(outside_manifest)\"\n")
                run(pipeline(`git -C $repo init -q`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $repo add Project.toml`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $repo -c user.email=t@example.com -c user.name=t commit -q -m init`;
                        stdout = devnull,
                        stderr = devnull,
                    )
                )
                @test_throws ArgumentError DistSSHRun.ensure_manifest_in_git_worktree!(repo)

                held = joinpath(root, "held")
                mkpath(held)
                inside_lock = joinpath(held, "inside.toml")
                write(inside_lock, "# inside\n")
                ext = joinpath(root, "extlocks")
                mkpath(ext)
                ext_manifest = joinpath(ext, "Manifest.toml")
                symlink(inside_lock, ext_manifest)
                write(
                    joinpath(held, "Project.toml"),
                    "name = \"Held\"\nmanifest = \"$(ext_manifest)\"\n",
                )
                run(pipeline(`git -C $held init -q`; stdout = devnull, stderr = devnull))
                @test_throws ArgumentError DistSSHRun.ensure_manifest_in_git_worktree!(held)

                nest = joinpath(root, "nest")
                nest_member = joinpath(nest, "lab", "experiments", "run1")
                mkpath(nest_member)
                write(
                    joinpath(nest, "lab", "Project.toml"),
                    "name = \"NestLab\"\n[workspace]\nprojects = [\"experiments/run1\"]\n",
                )
                write(joinpath(nest, "lab", "Manifest.toml"), "# lock\n")
                write(joinpath(nest_member, "Project.toml"), "name = \"NestRun\"\n[deps]\n")
                run(pipeline(`git -C $nest init -q`; stdout = devnull, stderr = devnull))
                withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => nothing) do
                    nest_deploy = DistSSHRun.remote_deploy_root(nest_member)
                    @test DistSSHRun.remote_git_clone_dest(nest_member) == dirname(nest_deploy)
                    @test DistSSHRun.remote_delete_root(nest_member) == dirname(nest_deploy)
                    @test DistSSHRun.remote_delete_root(nest_member; cli_override = "/srv/job") == "/srv/job"
                    @test_throws ArgumentError DistSSHRun.remote_git_clone_dest(
                        nest_member; cli_override = "/srv/job",
                    )
                end
            end
        end
    end

    @testset "path sources must ship with the lock" begin
        _with_tempdir() do root
            job = joinpath(root, "job")
            foo = joinpath(job, "dev", "Foo")
            mkpath(foo)
            write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(job, "Manifest.toml"), "# lock\n")
            write(
                joinpath(job, "Project.toml"),
                """
                name = "Job"
                [sources]
                Foo = {path = "dev/Foo"}
                Bar = {url = "https://example.invalid/Bar.jl.git"}
                """,
            )
            shipped = DistSSHRun.ensure_manifest_ships!(job)
            @test shipped.env_dir == DistSSHRun.canonical_local_path(job)

            abs_foo = DistSSHRun.canonical_local_path(foo)
            write(
                joinpath(job, "Project.toml"),
                """
                name = "Job"
                [sources]
                Foo = {path = "$(abs_foo)"}
                """,
            )
            @test_throws ArgumentError(
                "Source path $abs_foo for Foo is absolute. Workers resolve it on their own filesystem, so it would not be the staged tree.",
            ) DistSSHRun.ensure_manifest_ships!(job)
            write(
                joinpath(job, "Project.toml"),
                """
                name = "Job"
                [sources]
                Foo = {path = "~/nope"}
                """,
            )
            @test_throws ArgumentError(
                "Source path ~/nope for Foo is absolute. Workers resolve it on their own filesystem, so it would not be the staged tree.",
            ) DistSSHRun.ensure_manifest_ships!(job)

            write(
                joinpath(job, "Project.toml"),
                """
                name = "Job"
                [sources]
                Foo = {path = "dev/Missing"}
                """,
            )
            @test_throws ArgumentError("Source path $(DistSSHRun.canonical_local_path(joinpath(job, "dev", "Missing"))) for Foo does not exist. Workers would not see this path.") DistSSHRun.ensure_manifest_ships!(job)
            write(joinpath(job, "dev", "Missing"), "not a directory\n")
            @test_throws ArgumentError("Source path $(DistSSHRun.canonical_local_path(joinpath(job, "dev", "Missing"))) for Foo is not a directory. Workers would not see this path.") DistSSHRun.ensure_manifest_ships!(job)
            rm(joinpath(job, "dev", "Missing"))

            outside = joinpath(root, "ext", "Baz")
            mkpath(outside)
            write(joinpath(outside, "Project.toml"), "name = \"Baz\"\n")
            write(
                joinpath(job, "Project.toml"),
                """
                name = "Job"
                [sources]
                Baz = {path = "../ext/Baz"}
                """,
            )
            @test_throws ArgumentError DistSSHRun.ensure_manifest_ships!(job)

            rm(joinpath(job, "Project.toml"))
            write(
                joinpath(job, "Project.toml"),
                """
                name = "Job"
                [sources]
                Baz = {path = "dev/Baz"}
                """,
            )
            symlink(outside, joinpath(job, "dev", "Baz"))
            @test_throws ArgumentError DistSSHRun.ensure_manifest_ships!(job)

            lab = joinpath(root, "lab")
            member = joinpath(lab, "experiments", "run1")
            inner = joinpath(lab, "dev", "Foo")
            mkpath(member)
            mkpath(inner)
            write(joinpath(inner, "Project.toml"), "name = \"Foo\"\n")
            write(
                joinpath(lab, "Project.toml"),
                """
                name = "Lab"
                [workspace]
                projects = ["experiments/run1"]
                """,
            )
            write(joinpath(lab, "Manifest.toml"), "# lock\n")
            write(
                joinpath(member, "Project.toml"),
                """
                name = "Run1"
                [sources]
                Foo = {path = "../../dev/Foo"}
                """,
            )
            @test DistSSHRun.ensure_manifest_ships!(member).env_dir ==
                DistSSHRun.canonical_local_path(lab)
            write(
                joinpath(member, "Project.toml"),
                """
                name = "Run1"
                [sources]
                Baz = {path = "../../../ext/Baz"}
                """,
            )
            @test_throws ArgumentError DistSSHRun.ensure_manifest_ships!(member)

            if Sys.which("git") !== nothing
                repo = joinpath(root, "srcjob")
                foo_src = joinpath(repo, "dev", "Foo")
                mkpath(foo_src)
                write(joinpath(foo_src, "Project.toml"), "name = \"Foo\"\n")
                write(joinpath(repo, "Manifest.toml"), "# lock\n")
                write(
                    joinpath(repo, "Project.toml"),
                    """
                    name = "Src"
                    [sources]
                    Foo = {path = "dev/Foo"}
                    """,
                )
                run(pipeline(`git -C $repo init -q`; stdout = devnull, stderr = devnull))
                foo_loc = DistSSHRun.canonical_local_path(foo_src)
                @test_throws ArgumentError(
                    "Source path $foo_loc for Foo is not in the git commit a clone or git sync would send.",
                ) DistSSHRun.ensure_manifest_in_git_worktree!(repo)
                run(pipeline(`git -C $repo add -A`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $repo -c user.email=kit@example.com -c user.name=kit commit -q -m init`;
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
                @test DistSSHRun.ensure_manifest_in_git_worktree!(repo) === nothing
                alias = joinpath(root, "srcjob-alias")
                symlink(repo, alias)
                @test DistSSHRun.ensure_manifest_in_git_worktree!(alias) === nothing

                write(joinpath(repo, ".gitignore"), "dev/Foo/\n")
                run(pipeline(`git -C $repo add -A`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $repo -c user.email=kit@example.com -c user.name=kit commit -q -m ignore`;
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
                @test DistSSHRun.ensure_manifest_in_git_worktree!(repo) === nothing

                bar_src = joinpath(repo, "dev", "Bar")
                mkpath(bar_src)
                write(joinpath(bar_src, "Project.toml"), "name = \"Bar\"\n")
                write(
                    joinpath(repo, "Project.toml"),
                    """
                    name = "Src"
                    [sources]
                    Bar = {path = "dev/Bar"}
                    """,
                )
                bar_loc = DistSSHRun.canonical_local_path(bar_src)
                @test_throws ArgumentError(
                    "Source path $bar_loc for Bar is not in the git commit a clone or git sync would send.",
                ) DistSSHRun.ensure_manifest_in_git_worktree!(repo)

                write(joinpath(repo, ".gitignore"), "dev/Foo/\ndev/Skip/\n")
                skip_src = joinpath(repo, "dev", "Skip")
                mkpath(skip_src)
                write(joinpath(skip_src, "Project.toml"), "name = \"Skip\"\n")
                write(
                    joinpath(repo, "Project.toml"),
                    """
                    name = "Src"
                    [sources]
                    Skip = {path = "dev/Skip"}
                    """,
                )
                skip_loc = DistSSHRun.canonical_local_path(skip_src)
                @test_throws ArgumentError(
                    "Source path $skip_loc for Skip is not in the git commit a clone or git sync would send.",
                ) DistSSHRun.ensure_manifest_in_git_worktree!(repo)

                loose = joinpath(repo, "vendor", "Loose")
                mkpath(loose)
                write(joinpath(loose, "Project.toml"), "name = \"Loose\"\n")
                symlink(joinpath("..", "vendor", "Loose"), joinpath(repo, "dev", "Loose"))
                run(pipeline(`git -C $repo add -- dev/Loose`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $repo -c user.email=kit@example.com -c user.name=kit commit -q -m link`;
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
                write(
                    joinpath(repo, "Project.toml"),
                    """
                    name = "Src"
                    [sources]
                    Loose = {path = "dev/Loose"}
                    """,
                )
                link_loc = DistSSHRun.canonical_local_path(joinpath(repo, "dev", "Loose"))
                @test_throws ArgumentError(
                    "Source path $link_loc for Loose is a symlink to ../vendor/Loose in the git commit, which a clone or git sync would omit.",
                ) DistSSHRun.ensure_manifest_in_git_worktree!(repo)

                inn = joinpath(repo, "vendor", "In")
                mkpath(inn)
                write(joinpath(inn, "Project.toml"), "name = \"In\"\n")
                symlink(joinpath("..", "vendor", "In"), joinpath(repo, "dev", "Rel"))
                run(pipeline(`git -C $repo add -- vendor/In dev/Rel`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $repo -c user.email=kit@example.com -c user.name=kit commit -q -m rel`;
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
                write(
                    joinpath(repo, "Project.toml"),
                    """
                    name = "Src"
                    [sources]
                    Rel = {path = "dev/Rel"}
                    """,
                )
                @test DistSSHRun.ensure_manifest_in_git_worktree!(repo) === nothing

                abs_in = DistSSHRun.canonical_local_path(inn)
                symlink(abs_in, joinpath(repo, "dev", "Abs"))
                run(pipeline(`git -C $repo add -- dev/Abs`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $repo -c user.email=kit@example.com -c user.name=kit commit -q -m abs`;
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
                write(
                    joinpath(repo, "Project.toml"),
                    """
                    name = "Src"
                    [sources]
                    Abs = {path = "dev/Abs"}
                    """,
                )
                abs_loc = DistSSHRun.canonical_local_path(joinpath(repo, "dev", "Abs"))
                @test_throws ArgumentError(
                    "Source path $abs_loc for Abs is a symlink to $abs_in in the git commit. A clone keeps that absolute target.",
                ) DistSSHRun.ensure_manifest_in_git_worktree!(repo)

                esc = joinpath(repo, "dev", "Esc")
                symlink(joinpath("..", "..", "ext", "Baz"), esc)
                run(pipeline(`git -C $repo add -- dev/Esc`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $repo -c user.email=kit@example.com -c user.name=kit commit -q -m esc`;
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
                rm(esc)
                symlink("Foo", esc)
                write(
                    joinpath(repo, "Project.toml"),
                    """
                    name = "Src"
                    [sources]
                    Esc = {path = "dev/Esc"}
                    """,
                )
                esc_loc = DistSSHRun.canonical_local_path(esc)
                top = DistSSHRun.git_work_tree(repo)
                @test_throws ArgumentError(
                    "Source path $esc_loc for Esc is a symlink to ../../ext/Baz in the git commit, outside the git work tree ($top). The path would not reach a clone or git sync.",
                ) DistSSHRun.ensure_manifest_in_git_worktree!(repo)

                write(
                    joinpath(repo, "Project.toml"),
                    """
                    name = "Src"
                    [sources]
                    Baz = {path = "../ext/Baz"}
                    """,
                )
                @test_throws ArgumentError DistSSHRun.ensure_manifest_in_git_worktree!(repo)
            end
        end
    end

    @testset "path sources the review would have dropped" begin
        _with_tempdir() do base
            job = joinpath(base, "job")
            vendor = joinpath(job, "vendor", "Foo")
            link = joinpath(job, "dev", "Foo")
            mkpath(vendor)
            mkpath(dirname(link))
            write(joinpath(vendor, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(job, "Manifest.toml"), "# lock\n")
            write(
                joinpath(job, "Project.toml"),
                """
                name = "Job"
                [sources]
                Foo = {path = "dev/Foo"}
                """,
            )
            symlink(joinpath("..", "vendor", "Foo"), link)
            @test DistSSHRun.ensure_manifest_ships!(job).env_dir ==
                DistSSHRun.canonical_local_path(job)
            rm(link)
            abs_vendor = DistSSHRun.canonical_local_path(vendor)
            symlink(abs_vendor, link)
            link_loc = DistSSHRun.canonical_local_path(link)
            @test_throws ArgumentError(
                "Source path $link_loc for Foo is a symlink to $abs_vendor. rsync keeps that absolute target, so workers would not see the staged tree.",
            ) DistSSHRun.ensure_manifest_ships!(job)
            rm(link)
            symlink("~/nope", link)
            @test_throws ArgumentError(
                "Source path $link_loc for Foo is a symlink to ~/nope. rsync keeps that absolute target, so workers would not see the staged tree.",
            ) DistSSHRun.ensure_manifest_ships!(job)

            if Sys.which("git") !== nothing
                # `/var` -> `/private/var`: git's toplevel and Julia's path differ.
                phys = joinpath(base, "private", "var", "repo")
                foo = joinpath(phys, "dev", "Foo")
                inn = joinpath(phys, "vendor", "In")
                mkpath(foo)
                mkpath(inn)
                write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
                write(joinpath(inn, "Project.toml"), "name = \"In\"\n")
                write(joinpath(phys, "Manifest.toml"), "# lock\n")
                write(
                    joinpath(phys, "Project.toml"),
                    """
                    name = "Src"
                    [sources]
                    Foo = {path = "dev/Foo"}
                    """,
                )
                symlink(joinpath("private", "var"), joinpath(base, "var"))
                logical = joinpath(base, "var", "repo")
                run(pipeline(`git -C $phys init -q`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $phys add -A`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $phys -c user.email=kit@example.com -c user.name=kit commit -q -m init`;
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
                top = DistSSHRun.git_work_tree(logical)
                foo_logical = joinpath(logical, "dev", "Foo")
                @test DistSSHRun._git_worktree_relpath(top, foo_logical) == "dev/Foo"
                @test !startswith(DistSSHRun._git_worktree_relpath(top, foo_logical), "..")
                @test DistSSHRun.ensure_manifest_in_git_worktree!(logical) === nothing

                abs_foo = DistSSHRun.canonical_local_path(foo_logical)
                write(
                    joinpath(logical, "Project.toml"),
                    """
                    name = "Src"
                    [sources]
                    Foo = {path = "$(abs_foo)"}
                    """,
                )
                @test_throws ArgumentError(
                    "Source path $abs_foo for Foo is absolute. Workers resolve it on their own filesystem, so it would not be the staged tree.",
                ) DistSSHRun.ensure_manifest_in_git_worktree!(logical)

                write(
                    joinpath(phys, "Project.toml"),
                    """
                    name = "Src"
                    [sources]
                    In = {path = "dev/In"}
                    """,
                )
                symlink(joinpath("..", "vendor", "In"), joinpath(phys, "dev", "In"))
                run(pipeline(`git -C $phys add -- vendor/In dev/In Project.toml`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $phys -c user.email=kit@example.com -c user.name=kit commit -q -m rel`;
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
                in_logical = joinpath(logical, "dev", "In")
                @test DistSSHRun._git_worktree_relpath(top, in_logical) == "dev/In"
                @test DistSSHRun.ensure_manifest_in_git_worktree!(logical) === nothing

                abs_inn = DistSSHRun.canonical_local_path(joinpath(logical, "vendor", "In"))
                symlink(abs_inn, joinpath(phys, "dev", "Abs"))
                run(pipeline(`git -C $phys add -- dev/Abs`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $phys -c user.email=kit@example.com -c user.name=kit commit -q -m abs`;
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
                write(
                    joinpath(phys, "Project.toml"),
                    """
                    name = "Src"
                    [sources]
                    Abs = {path = "dev/Abs"}
                    """,
                )
                abs_loc = DistSSHRun.canonical_local_path(joinpath(logical, "dev", "Abs"))
                @test_throws ArgumentError(
                    "Source path $abs_loc for Abs is a symlink to $abs_inn in the git commit. A clone keeps that absolute target.",
                ) DistSSHRun.ensure_manifest_in_git_worktree!(logical)
            end
        end
    end

    @testset "go cwd is the member project" begin
        member = "~/lab/experiments/run1"
        inner = DistSSHRun._go_remote_slot_shell_inner(
            member,
            "slot",
            "job.jl",
            String[],
            "julia",
        )
        @test occursin("experiments/run1", inner)
        @test occursin("--project=.", inner)
        @test !occursin("--project=experiments", inner)
    end
end
