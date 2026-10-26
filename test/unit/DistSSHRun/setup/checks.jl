using Test
using Pkg

@testset "setup checks" begin
    DistSSHRun.print_juliaup_align_fix!("user@host"; kind = :missing, channel = "1.12")
    DistSSHRun.print_juliaup_align_fix!("user@host"; kind = :mismatch, channel = "1.12")
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
    @test occursin("up update 1.12 parent", tip_out)
    @test occursin("up default 1.12 parent", tip_out)
    @test !DistSSHRun.print_juliaup_parent_patch_note!(
        v"1.14.0-alpha1"; local_version = v"1.14.0-alpha1", channel = "1.14.0-alpha1",
    )
    @test !DistSSHRun.print_juliaup_parent_patch_note!(
        v"1.13.2"; local_version = v"1.13.2+0.aarch64", channel = "1.13",
    )
    pinned_out, _ = with_kit_verbosity(:verbose) do
        _capture_stdio() do _, _
            @test DistSSHRun.print_juliaup_parent_patch_note!(
                v"1.14.0"; local_version = v"1.14.0-alpha1", channel = "1.14.0-alpha1",
            )
        end
    end
    @test occursin("may not be installed", pinned_out)
    @test occursin("juliaup add 1.14.0-alpha1", pinned_out)
    @test !occursin("behind", pinned_out)
    @test !occursin("up update", pinned_out)
    nightly_out, _ = with_kit_verbosity(:verbose) do
        _capture_stdio() do _, _
            @test DistSSHRun.print_juliaup_parent_patch_note!(
                v"1.14.0-DEV.2000"; local_version = v"1.14.0-DEV.1000", channel = "1.14-nightly",
            )
        end
    end
    @test occursin("behind", nightly_out)
    @test occursin("up update 1.14-nightly parent", nightly_out)
    pre_warnings = DistSSHRun.SetupWarning[]
    pre_out, pre_ok = with_kit_verbosity(:verbose) do
        _capture_stdio() do _, _
            DistSSHRun._report_remote_julia!(
                "worker",
                "/usr/bin/julia",
                (found = true, version = v"1.14.0-alpha1", mismatch_kind = :prerelease),
                true,
                pre_warnings,
            )
        end
    end
    @test pre_ok
    @test occursin("prerelease", pre_out)
    @test !occursin("✗", pre_out)
    @test length(pre_warnings) == 1
    @test pre_warnings[1].kind === :julia_prerelease
    @test pre_warnings[1].host == "worker"
    patch_warnings = DistSSHRun.SetupWarning[]
    patch_out, patch_ok = with_kit_verbosity(:verbose) do
        _capture_stdio() do _, _
            DistSSHRun._report_remote_julia!(
                "worker",
                "/usr/bin/julia",
                (found = true, version = v"1.13.2", mismatch_kind = :patch),
                true,
                patch_warnings,
            )
        end
    end
    @test patch_ok
    @test occursin("patch", patch_out)
    @test length(patch_warnings) == 1
    @test patch_warnings[1].kind === :julia_patch
    @test patch_warnings[1].host == "worker"
    _, minor_fail = with_kit_verbosity(:verbose) do
        _capture_stdio() do _, _
            DistSSHRun._report_remote_julia!(
                "worker",
                "/usr/bin/julia",
                (found = true, version = v"1.12.0", mismatch_kind = :minor),
                false,
            )
        end
    end
    @test !minor_fail
    mktempdir() do d
        fake = _write_aligned_fake_juliaup(d)
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => fake.ju) do
            out, _ = with_kit_verbosity(:progress) do
                _capture_stdio() do _, _
                    DistSSHRun.juliaup_align_remotes(["parent"]; confirm = false)
                end
            end
            @test occursin("parent: already on $(fake.ch)", out)
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
        probed = DistSSHRun.probe_project_deps(dir)
        @test probed !== nothing
        @test occursin("Manifest.toml not found", probed)
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
            run(pipeline(`git -C $dir -c commit.gpgsign=false commit -q -m init`; stdout = devnull, stderr = devnull))
            if Sys.which("ssh") !== nothing && Sys.which("rsync") !== nothing
                _, result_clean = with_kit_verbosity(:verbose) do
                    _capture_stdio() do _, _
                        DistSSHRun.check_prerequisites(
                            String[], "auto", "~/App.jl", dir;
                            require_clean_git = false,
                        )
                    end
                end
                @test isempty(result_clean.warnings)
            end
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
            dirty = filter(w -> w.kind === :git_dirty, result_warn.warnings)
            @test length(dirty) == 1
            @test dirty[1].host == DistSSHRun.PARENT_HOST_NAME
            @test dirty[1].message == "Git has uncommitted changes"

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
            @test !any(w -> w.kind === :git_dirty, result_fail.warnings)
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
            shipped = DistSSHRun.ensure_manifest_ships!(member)
            @test shipped.env_dir == DistSSHRun.canonical_local_path(lab)

            elsewhere = joinpath(root, "elsewhere")
            mkpath(elsewhere)
            outside_manifest = joinpath(root, "side", "Manifest.toml")
            mkpath(dirname(outside_manifest))
            write(outside_manifest, "# x\n")
            write(
                joinpath(elsewhere, "Project.toml"),
                "name = \"Out\"\nmanifest = \"$(outside_manifest)\"\n",
            )
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
                        `git -C $repo -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -q -m init`;
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
                write(joinpath(repo, "Project.toml"), "name = \"Src\"\n")
                run(pipeline(`git -C $repo init -q`; stdout = devnull, stderr = devnull))
                out_nocommit, = _capture_stdio() do _, _
                    @test DistSSHRun.ensure_manifest_in_git_worktree!(repo) === nothing
                end
                @test occursin("has no commit yet", out_nocommit)
                @test occursin("will be an error", out_nocommit)
                write(
                    joinpath(repo, "Project.toml"),
                    """
                    name = "Src"
                    [sources]
                    Foo = {path = "dev/Foo"}
                    """,
                )
                run(pipeline(`git -C $repo add -A`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $repo -c user.email=kit@example.com -c user.name=kit -c commit.gpgsign=false commit -q -m init`;
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
                        `git -C $repo -c user.email=kit@example.com -c user.name=kit -c commit.gpgsign=false commit -q -m ignore`;
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
                        `git -C $repo -c user.email=kit@example.com -c user.name=kit -c commit.gpgsign=false commit -q -m link`;
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
                        `git -C $repo -c user.email=kit@example.com -c user.name=kit -c commit.gpgsign=false commit -q -m rel`;
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
                        `git -C $repo -c user.email=kit@example.com -c user.name=kit -c commit.gpgsign=false commit -q -m abs`;
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
                        `git -C $repo -c user.email=kit@example.com -c user.name=kit -c commit.gpgsign=false commit -q -m esc`;
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
                        `git -C $phys -c user.email=kit@example.com -c user.name=kit -c commit.gpgsign=false commit -q -m init`;
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
                top = DistSSHRun.git_work_tree(logical)
                @test top !== nothing
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
                        `git -C $phys -c user.email=kit@example.com -c user.name=kit -c commit.gpgsign=false commit -q -m rel`;
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
                        `git -C $phys -c user.email=kit@example.com -c user.name=kit -c commit.gpgsign=false commit -q -m abs`;
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

    @testset "manifest and path-source files must be the bytes that ship" begin
        Sys.which("git") === nothing && return
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, "Manifest.toml"), "# lock\n")
            write(joinpath(tmp, ".gitignore"), "Manifest.toml\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.email "test@example.com"`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp config user.name "Test"`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp add Project.toml .gitignore`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp -c commit.gpgsign=false commit -q -m init`; stdout = devnull, stderr = devnull))
            out_rsync, = _capture_stdio() do _, _
                @test DistSSHRun.ensure_manifest_ships!(tmp).env_dir ==
                    DistSSHRun.canonical_local_path(tmp)
            end
            @test occursin("not in the rsync send list", out_rsync)
            @test occursin("will be an error", out_rsync)
            out_git, = _capture_stdio() do _, _
                @test DistSSHRun.ensure_manifest_in_git_worktree!(tmp) === nothing
            end
            @test occursin("is not tracked", out_git)
            @test occursin("will be an error", out_git)

            rm(joinpath(tmp, ".gitignore"))
            run(pipeline(`git -C $tmp add -A`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp -c commit.gpgsign=false commit -q -m track`; stdout = devnull, stderr = devnull))
            @test DistSSHRun.ensure_manifest_in_git_worktree!(tmp) === nothing
            open(joinpath(tmp, "Manifest.toml"), "a") do io
                println(io, "# dirty")
            end
            out_dirty, = _capture_stdio() do _, _
                @test DistSSHRun.ensure_manifest_in_git_worktree!(tmp) === nothing
            end
            @test occursin("uncommitted changes", out_dirty)
            run(pipeline(`git -C $tmp checkout -q -- Manifest.toml`; stdout = devnull, stderr = devnull))

            foo = joinpath(tmp, "vendor", "Foo")
            mkpath(joinpath(foo, "lib"))
            mkpath(joinpath(foo, "docs", "build"))
            write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(foo, "docs", "build", "index.html"), "<p></p>\n")
            write(joinpath(foo, "Manifest.toml"), "# dep lock\n")
            write(
                joinpath(tmp, "Project.toml"), """
                name = "App"
                [sources]
                Foo = {path = "vendor/Foo"}
                """
            )
            write(joinpath(tmp, ".gitignore"), "lib/\ndocs/build/\nvendor/**/Manifest.toml\n")
            run(pipeline(`git -C $tmp add -A`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp -c commit.gpgsign=false commit -q -m foo`; stdout = devnull, stderr = devnull))
            # Path-source Manifest under app gitignore must not warn.
            out_dep_manifest, = _capture_stdio() do _, _
                @test DistSSHRun.ensure_manifest_in_git_worktree!(tmp) === nothing
            end
            @test !occursin("vendor/Foo/Manifest.toml", out_dep_manifest)
            @test !occursin("will be an error", out_dep_manifest)
            write(joinpath(foo, "lib", "x.jl"), "x = 1\n")
            out_jl, = _capture_stdio() do _, _
                @test DistSSHRun.ensure_manifest_in_git_worktree!(tmp) === nothing
            end
            @test occursin("ignored by this repo", out_jl)
            @test occursin("will be an error", out_jl)
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "vendor/Foo/lib/x.jl" in listed
            @test DistSSHRun.ensure_manifest_ships!(tmp).env_dir == DistSSHRun.canonical_local_path(tmp)
            rm(joinpath(foo, "lib", "x.jl"))
            @test DistSSHRun.ensure_manifest_in_git_worktree!(tmp) === nothing
            # Untracked project files use the same ship names as ignored files.
            bar = joinpath(tmp, "vendor", "Bar")
            mkpath(joinpath(bar, "src"))
            write(joinpath(bar, "src", "Bar.jl"), "module Bar end\n")
            write(
                joinpath(tmp, "Project.toml"), """
                name = "App"
                [sources]
                Foo = {path = "vendor/Foo"}
                Bar = {path = "vendor/Bar"}
                """
            )
            run(pipeline(`git -C $tmp add Project.toml vendor/Bar/src`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp -c commit.gpgsign=false commit -q -m bar-src`; stdout = devnull, stderr = devnull))
            write(joinpath(bar, "Project.toml"), "name = \"Bar\"\n")
            out_proj, = _capture_stdio() do _, _
                @test DistSSHRun.ensure_manifest_in_git_worktree!(tmp) === nothing
            end
            @test occursin("untracked files", out_proj)
            @test occursin("vendor/Bar/Project.toml", out_proj)
            @test occursin("will be an error", out_proj)
            write(joinpath(bar, "Manifest.toml"), "# dep lock\n")
            write(joinpath(bar, "LocalPreferences.toml"), "[Bar]\nx = 1\n")
            out_skip, = _capture_stdio() do _, _
                @test DistSSHRun.ensure_manifest_in_git_worktree!(tmp) === nothing
            end
            @test !occursin("vendor/Bar/Manifest.toml", out_skip)
            @test !occursin("LocalPreferences.toml", out_skip)
            @test occursin("vendor/Bar/Project.toml", out_skip)
            run(pipeline(`git -C $tmp add vendor/Bar/Project.toml`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp -c commit.gpgsign=false commit -q -m bar-proj`; stdout = devnull, stderr = devnull))

            # Path-source symlink: ignored files under the target must warn.
            mkpath(joinpath(tmp, "dev"))
            symlink(joinpath("..", "vendor", "Foo"), joinpath(tmp, "dev", "Foo"))
            write(
                joinpath(tmp, "Project.toml"), """
                name = "App"
                [sources]
                Foo = {path = "dev/Foo"}
                """
            )
            write(joinpath(foo, "lib", "x.jl"), "x = 1\n")
            run(pipeline(`git -C $tmp add Project.toml dev/Foo`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp -c commit.gpgsign=false commit -q -m link-foo`; stdout = devnull, stderr = devnull))
            out_link, = _capture_stdio() do _, _
                @test DistSSHRun.ensure_manifest_in_git_worktree!(tmp) === nothing
            end
            @test occursin("ignored by this repo", out_link)
            @test occursin("vendor/Foo/lib/x.jl", out_link)
            @test occursin("will be an error", out_link)
            rm(joinpath(foo, "lib", "x.jl"))

            # Manifest symlink: the lock bytes must be at HEAD, not only the link.
            write(joinpath(tmp, "Manifest-real.toml"), "# lock\n")
            rm(joinpath(tmp, "Manifest.toml"))
            symlink("Manifest-real.toml", joinpath(tmp, "Manifest.toml"))
            run(pipeline(`git -C $tmp add Manifest.toml`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp -c commit.gpgsign=false commit -q -m manifest-link`; stdout = devnull, stderr = devnull))
            out_mlink, = _capture_stdio() do _, _
                @test DistSSHRun.ensure_manifest_in_git_worktree!(tmp) === nothing
            end
            @test occursin("Manifest-real.toml", out_mlink)
            @test occursin("is not tracked", out_mlink)
            @test occursin("will be an error", out_mlink)
            run(pipeline(`git -C $tmp add Manifest-real.toml`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $tmp -c commit.gpgsign=false commit -q -m manifest-bytes`; stdout = devnull, stderr = devnull))
            quiet_mlink, = _capture_stdio() do _, _
                @test DistSSHRun.ensure_manifest_in_git_worktree!(tmp) === nothing
            end
            @test !occursin("will be an error", quiet_mlink)
        end
    end

    @testset "a malformed Project.toml stays on the warning path" begin
        Sys.which("git") === nothing && return
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"Bad\"\n[deps\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            out, = _capture_stdio() do _, _
                @test DistSSHRun._warn_git_worktree_ship!(tmp) === nothing
            end
            @test occursin("could not read", out)
            @test occursin("Project.toml", out)
        end
    end

    @testset "SetupWarning is public and SyncResult keeps its constructors" begin
        @test Base.ispublic(DistSSHRun, :SetupWarning)
        @test !Base.isexported(DistSSHRun, :SetupWarning)
        positional = DistSSHRun.SyncResult(true, DistSSHRun.HostResult[], false)
        keyword = DistSSHRun.SyncResult(false, DistSSHRun.HostResult[]; ok = true)
        @test isempty(positional.warnings)
        @test isempty(keyword.warnings)
        @test positional.ok
        @test keyword.ok
    end
end
