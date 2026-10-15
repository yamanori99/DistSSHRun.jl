using Test

# Oracle: `_rsync_send_list` against a temporary git repository. No rsync, no SSH.

@testset "rsync send list" begin
    function _ident!(dir)
        run(pipeline(`git -C $dir config user.email "test@example.com"`; stdout = devnull, stderr = devnull))
        run(pipeline(`git -C $dir config user.name "Test"`; stdout = devnull, stderr = devnull))
        return nothing
    end

    function _commit!(dir, message)
        run(pipeline(`git -C $dir add -A`; stdout = devnull, stderr = devnull))
        run(pipeline(`git -C $dir commit -q -m $message`; stdout = devnull, stderr = devnull))
        return nothing
    end

    Sys.which("git") === nothing && return

    @testset "negation, info/exclude, and deleted files" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "data/*\n!data/keep.txt\n")
            mkpath(joinpath(tmp, "data"))
            write(joinpath(tmp, "data", "a.dat"), "x\n")
            write(joinpath(tmp, "data", "keep.txt"), "keep\n")
            write(joinpath(tmp, "gone.txt"), "gone\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            _commit!(tmp, "init")
            rm(joinpath(tmp, "gone.txt"))
            mkpath(joinpath(tmp, ".git", "info"))
            write(joinpath(tmp, ".git", "info", "exclude"), "secret.txt\n")
            write(joinpath(tmp, "secret.txt"), "nope\n")
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test listed isa Vector
            @test "data/keep.txt" in listed
            @test !("data/a.dat" in listed)
            # info/exclude is not applied (same as rsync `:- .gitignore`).
            @test "secret.txt" in listed
            @test !("gone.txt" in listed)
            @test "data" in listed
        end
    end

    @testset "empty and ignored directories" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "output/*\nbuild/\n")
            mkpath(joinpath(tmp, "output"))
            write(joinpath(tmp, "output", "x.bin"), "x\n")
            mkpath(joinpath(tmp, "empty"))
            mkpath(joinpath(tmp, "build", "obj"))
            write(joinpath(tmp, "build", "obj", "a.o"), "o\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            _commit!(tmp, "init")
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "output" in listed
            @test !("output/x.bin" in listed)
            @test "empty" in listed
            @test !("build" in listed)
            @test !("build/obj" in listed)
            @test !("build/obj/a.o" in listed)
        end
    end

    @testset "a negated pattern keeps an empty directory" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "*/\n!keep/\n")
            mkpath(joinpath(tmp, "keep"))
            mkpath(joinpath(tmp, "build"))
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "keep" in listed
            @test !("build" in listed)
        end
    end

    @testset "a re-included directory keeps its file" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "*/\n!keep/\n")
            mkpath(joinpath(tmp, "keep"))
            write(joinpath(tmp, "keep", "a.txt"), "x\n")
            mkpath(joinpath(tmp, "build"))
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "keep" in listed
            @test "keep/a.txt" in listed
            @test !("build" in listed)
        end
    end

    @testset "a later pattern ignores the directory again" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "*/\n!keep/\nkeep/\n")
            mkpath(joinpath(tmp, "keep"))
            mkpath(joinpath(tmp, "build"))
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test !("keep" in listed)
            @test !("build" in listed)
        end
    end

    @testset "an escaped bang still ignores the directory" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, ".gitignore"), "\\!keep/\n")
            mkpath(joinpath(tmp, "!keep"))
            mkpath(joinpath(tmp, "plain"))
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "plain" in listed
            @test !("!keep" in listed)
        end
    end

    @testset "git ls-files failure is an error" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            @test_throws ErrorException DistSSHRun._git_ls_files_z(
                tmp, ["--cached", "--others", "--exclude-per-directory=.gitignore"],
            )
        end
    end

    @testset "check-ignore exit 1 is no match" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "keep.txt"), "yes\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            @test isempty(DistSSHRun._git_check_ignore_records(tmp, ["keep.txt"]))
        end
    end

    @testset "check-ignore failure with empty stderr is an error" begin
        _with_tempdir() do tmp
            bindir = joinpath(tmp, "bin")
            mkpath(bindir)
            git = joinpath(bindir, "git")
            write(git, "#!/bin/sh\nexit 2\n")
            chmod(git, 0o755)
            err = withenv("PATH" => bindir * ":" * get(ENV, "PATH", "")) do
                try
                    DistSSHRun._git_check_ignore_records(tmp, ["a.txt"])
                    nothing
                catch e
                    e
                end
            end
            @test err isa ErrorException
            @test err.msg == "git check-ignore failed in $tmp"
        end
    end

    @testset "directory symlink is listed" begin
        _with_tempdir() do tmp
            # Path source that is not its own repo: walk must keep the symlink.
            write(
                joinpath(tmp, "Project.toml"), """
                name = "App"
                [sources]
                Link = {path = "vendor"}
                """
            )
            mkpath(joinpath(tmp, "vendor", "real"))
            write(joinpath(tmp, "vendor", "Project.toml"), "name = \"Link\"\n")
            write(joinpath(tmp, "vendor", "real", "x.jl"), "x = 1\n")
            symlink("real", joinpath(tmp, "vendor", "link"))
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            _commit!(tmp, "init")
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "vendor/link" in listed
        end
    end

    @testset "path source ignores the app gitignore" begin
        _with_tempdir() do tmp
            foo = joinpath(tmp, "vendor", "Foo")
            mkpath(joinpath(foo, "lib"))
            write(
                joinpath(tmp, "Project.toml"), """
                name = "App"
                [sources]
                Foo = {path = "vendor/Foo"}
                """
            )
            write(joinpath(tmp, ".gitignore"), "lib/\n")
            write(joinpath(foo, "Project.toml"), "name = \"Foo\"\n")
            write(joinpath(foo, "lib", "x.jl"), "x = 1\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            _commit!(tmp, "init")
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "vendor/Foo/lib/x.jl" in listed
        end
    end

    @testset "independent path source uses its own gitignore" begin
        _with_tempdir() do tmp
            dep = joinpath(tmp, "dep")
            mkpath(dep)
            write(joinpath(dep, ".gitignore"), "secret.txt\n")
            write(joinpath(dep, "keep.jl"), "k = 1\n")
            write(joinpath(dep, "secret.txt"), "nope\n")
            run(pipeline(`git -C $dep init -q`; stdout = devnull, stderr = devnull))
            _ident!(dep)
            _commit!(dep, "dep")
            write(
                joinpath(tmp, "Project.toml"), """
                name = "App"
                [sources]
                Dep = {path = "dep"}
                """
            )
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            _commit!(tmp, "app")
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "dep/keep.jl" in listed
            @test !("dep/secret.txt" in listed)
        end
    end

    @testset "nested repo and submodule are expanded" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            _commit!(tmp, "app")
            nested = joinpath(tmp, "nested")
            mkpath(nested)
            write(joinpath(nested, "a.jl"), "a = 1\n")
            run(pipeline(`git -C $nested init -q`; stdout = devnull, stderr = devnull))
            _ident!(nested)
            _commit!(nested, "nested")
            listed = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "nested/a.jl" in listed

            child = joinpath(tmp, "child-src")
            mkpath(child)
            write(joinpath(child, "inside.jl"), "i = 1\n")
            run(pipeline(`git -C $child init -q`; stdout = devnull, stderr = devnull))
            _ident!(child)
            _commit!(child, "child")
            sub = joinpath(tmp, "sub")
            run(pipeline(`git clone -q $child $sub`; stdout = devnull, stderr = devnull))
            sha = strip(read(`git -C $sub rev-parse HEAD`, String))
            run(pipeline(`git -C $tmp update-index --add --cacheinfo 160000,$sha,sub`; stdout = devnull, stderr = devnull))
            _commit!(tmp, "gitlink")
            listed2 = DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
            @test "sub/inside.jl" in listed2
        end
    end

    @testset "workspace member lists paths from env_dir" begin
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
            write(joinpath(lab, "lab.jl"), "1\n")
            write(joinpath(member, "Project.toml"), "name = \"Run1\"\n[deps]\n")
            write(joinpath(member, "job.jl"), "2\n")
            run(pipeline(`git -C $lab init -q`; stdout = devnull, stderr = devnull))
            _ident!(lab)
            _commit!(lab, "init")
            env = DistSSHRun.resolve_pkg_env(member)
            @test env.env_dir == DistSSHRun.canonical_local_path(lab)
            listed = DistSSHRun._rsync_send_list(env.env_dir, env)
            @test listed isa Vector
            @test "lab.jl" in listed
            @test "experiments/run1/job.jl" in listed
            for p in listed
                @test ispath(joinpath(env.env_dir, p))
            end
            # Listing from the member would not match the rsync source root (env_dir).
            wrong = DistSSHRun._rsync_send_list(member, env)
            @test "job.jl" in wrong
            @test !("lab.jl" in wrong)
            @test !ispath(joinpath(env.env_dir, "job.jl"))
        end
    end

    @testset "outside a work tree the caller keeps the filter" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            env = DistSSHRun.resolve_pkg_env(tmp)
            @test DistSSHRun._rsync_send_list(tmp, env) === nothing
            @test DistSSHRun.rsync_send_list(tmp, env) === nothing
        end
    end

    @testset "ancestor gitignore warns; info/exclude keeps the directory" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "dropped.txt\n")
            sub = joinpath(tmp, "sub")
            mkpath(sub)
            write(joinpath(sub, "Project.toml"), "name = \"App\"\n")
            write(joinpath(sub, "dropped.txt"), "nope\n")
            write(joinpath(sub, "keep.txt"), "yes\n")
            mkpath(joinpath(tmp, ".git", "info"))
            write(joinpath(tmp, ".git", "info", "exclude"), "hideme/\n")
            mkpath(joinpath(sub, "hideme"))
            write(joinpath(sub, "hideme", "a.txt"), "a\n")
            excludes = joinpath(tmp, "global-excludes")
            write(excludes, "globaldir/\n")
            mkpath(joinpath(sub, "globaldir"))
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            run(pipeline(`git -C $tmp config core.excludesFile $excludes`; stdout = devnull, stderr = devnull))
            _commit!(tmp, "init")
            env = DistSSHRun.resolve_pkg_env(sub)
            text = mktemp() do _, io
                redirect_stdout(io) do
                    listed = DistSSHRun.rsync_send_list(sub, env; warn = true)
                    @test listed isa Vector
                    @test !("dropped.txt" in listed)
                    @test "keep.txt" in listed
                    @test "hideme" in listed
                    @test "hideme/a.txt" in listed
                    @test "globaldir" in listed
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test count("Warning:", text) == 1
            @test occursin("1 untracked file left out", text)
            @test occursin("dropped.txt (.gitignore:1)", text)
            @test !occursin("info/exclude", text)
            @test !occursin("global-excludes", text)
        end
    end

    @testset "an ancestor negation keeps the directory" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "*/\n!sub/\n!sub/keep/\n")
            sub = joinpath(tmp, "sub")
            mkpath(sub)
            write(joinpath(sub, "Project.toml"), "name = \"App\"\n")
            mkpath(joinpath(sub, "keep"))
            mkpath(joinpath(sub, "build"))
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            listed = DistSSHRun._rsync_send_list(sub, DistSSHRun.resolve_pkg_env(sub))
            @test "keep" in listed
            @test !("build" in listed)
        end
    end

    @testset "an ancestor negation stays out of the warning" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "*.txt\n")
            sub = joinpath(tmp, "sub")
            mkpath(sub)
            write(joinpath(sub, ".gitignore"), "!kept.txt\n")
            write(joinpath(sub, "Project.toml"), "name = \"App\"\n")
            write(joinpath(sub, "dropped.txt"), "nope\n")
            write(joinpath(sub, "kept.txt"), "yes\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            env = DistSSHRun.resolve_pkg_env(sub)
            text = mktemp() do _, io
                redirect_stdout(io) do
                    listed = DistSSHRun.rsync_send_list(sub, env; warn = true)
                    @test "kept.txt" in listed
                    @test !("dropped.txt" in listed)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test count("Warning:", text) == 1
            @test occursin("dropped.txt (.gitignore:1)", text)
            @test !occursin("kept.txt", text)
        end
    end

    @testset "local ignores and tracked ancestor matches do not warn" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "tracked.txt\n")
            sub = joinpath(tmp, "sub")
            mkpath(sub)
            write(joinpath(sub, ".gitignore"), "local.txt\n")
            write(joinpath(sub, "Project.toml"), "name = \"App\"\n")
            write(joinpath(sub, "tracked.txt"), "tracked\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            run(
                pipeline(
                    `git -C $tmp add -f .gitignore sub/.gitignore sub/Project.toml sub/tracked.txt`;
                    stdout = devnull,
                    stderr = devnull,
                )
            )
            run(pipeline(`git -C $tmp commit -q -m init`; stdout = devnull, stderr = devnull))
            write(joinpath(sub, "local.txt"), "local\n")
            env = DistSSHRun.resolve_pkg_env(sub)
            text = mktemp() do _, io
                redirect_stdout(io) do
                    listed = DistSSHRun.rsync_send_list(sub, env; warn = true)
                    @test "tracked.txt" in listed
                    @test !("local.txt" in listed)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test !occursin("Warning:", text)
        end
    end

    @testset "an ancestor warning shows three paths and the remainder" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "*.tmp\n")
            sub = joinpath(tmp, "sub")
            mkpath(sub)
            write(joinpath(sub, "Project.toml"), "name = \"App\"\n")
            for name in ("a.tmp", "b.tmp", "c.tmp", "d.tmp", "e.tmp")
                write(joinpath(sub, name), "$name\n")
            end
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            _commit!(tmp, "init")
            env = DistSSHRun.resolve_pkg_env(sub)
            text = mktemp() do _, io
                redirect_stdout(io) do
                    listed = DistSSHRun.rsync_send_list(sub, env; warn = true)
                    for name in ("a.tmp", "b.tmp", "c.tmp", "d.tmp", "e.tmp")
                        @test !(name in listed)
                    end
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test count("Warning:", text) == 1
            @test occursin("5 untracked files left out", text)
            @test occursin("a.tmp (.gitignore:1)", text)
            @test occursin("b.tmp (.gitignore:1)", text)
            @test occursin("c.tmp (.gitignore:1)", text)
            @test !occursin("d.tmp", text)
            @test !occursin("e.tmp", text)
            @test occursin("and 2 more.", text)
        end
    end

    @testset "check-ignore records are complete" begin
        @test_throws ErrorException DistSSHRun._parse_check_ignore_verbose("only\0two")
        recs = DistSSHRun._parse_check_ignore_verbose("\0\0\0keep.txt\0")
        @test length(recs) == 1
        @test recs[1].path == "keep.txt"
        @test isempty(recs[1].source)
        @test isempty(recs[1].pattern)
    end

    @testset "a locally ignored directory is not expanded" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "data/\n")
            sub = joinpath(tmp, "sub")
            mkpath(joinpath(sub, "data"))
            write(joinpath(sub, "data", "x.csv"), "x\n")
            write(joinpath(sub, "data", "y.csv"), "y\n")
            write(joinpath(sub, ".gitignore"), "output/\n")
            mkpath(joinpath(sub, "output"))
            for name in ("a.txt", "b.txt", "c.txt")
                write(joinpath(sub, "output", name), "z\n")
            end
            write(joinpath(sub, "Project.toml"), "name = \"App\"\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            env = DistSSHRun.resolve_pkg_env(sub)
            probes = DistSSHRun._ancestor_gitignore_probes(sub)
            @test "data" in probes
            @test "output" in probes
            @test !any(startswith(p, "data/") for p in probes)
            @test !any(startswith(p, "output/") for p in probes)
            quiet = mktemp() do _, io
                redirect_stdout(io) do
                    DistSSHRun.rsync_send_list(sub, env)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test !occursin("Warning:", quiet)
            text = mktemp() do _, io
                redirect_stdout(io) do
                    DistSSHRun.rsync_send_list(sub, env; warn = true)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test count("Warning:", text) == 1
            @test occursin("2 untracked files left out", text)
            @test occursin("data/x.csv (.gitignore:1)", text)
            @test occursin("data/y.csv (.gitignore:1)", text)
            @test !occursin("output/", text)
        end
    end

    @testset "a symlinked send root still warns" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "dropped.txt\n")
            sub = joinpath(tmp, "sub")
            mkpath(sub)
            write(joinpath(sub, "Project.toml"), "name = \"App\"\n")
            write(joinpath(sub, "dropped.txt"), "nope\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            link = joinpath(tmp, "link")
            symlink(sub, link)
            env = DistSSHRun.resolve_pkg_env(link)
            text = mktemp() do _, io
                redirect_stdout(io) do
                    listed = DistSSHRun.rsync_send_list(link, env; warn = true)
                    @test !("dropped.txt" in listed)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test occursin("dropped.txt (.gitignore:1)", text)
            rootlink = joinpath(tmp, "rootlink")
            symlink(tmp, rootlink)
            @test isempty(DistSSHRun._ancestor_gitignore_probes(rootlink))
        end
    end

    @testset "ancestor warnings name each source" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, ".gitignore"), "a file.txt\nメモ.txt\n")
            mid = joinpath(tmp, "mid")
            mkpath(mid)
            write(joinpath(mid, ".gitignore"), "b.txt\n")
            sub = joinpath(mid, "sub")
            mkpath(sub)
            write(joinpath(sub, "Project.toml"), "name = \"App\"\n")
            write(joinpath(sub, "a file.txt"), "a\n")
            write(joinpath(sub, "メモ.txt"), "m\n")
            write(joinpath(sub, "b.txt"), "b\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            env = DistSSHRun.resolve_pkg_env(sub)
            text = mktemp() do _, io
                redirect_stdout(io) do
                    DistSSHRun.rsync_send_list(sub, env; warn = true)
                end
                flush(io)
                seekstart(io)
                return read(io, String)
            end
            @test count("Warning:", text) == 1
            @test occursin("3 untracked files left out", text)
            @test occursin("a file.txt (.gitignore:1)", text)
            @test occursin("メモ.txt (.gitignore:2)", text)
            @test occursin("b.txt (mid/.gitignore:1)", text)
        end
    end

    @testset "family public names stay public" begin
        base = DistSSHRun.DistSSHBase
        got = Set(n for n in names(base; all = true) if Base.ispublic(base, n))
        @test got ⊇ Set(
            [
                :PARENT_HOST_NAME,
                :cli_entry, :cli_heading, :cli_m, :cli_m_project, :cli_qhost, :cli_qhost_heading,
                :format_placement_token, :get_remote_julia_version, :julia_project_rel,
                :parse_placement_token, :remote_env_project_root, :resolve_remote_julia,
                :resolve_remote_project_root, :with_cli_entry,
            ]
        )
        up = DistSSHRun.DistSSHUp
        up_got = Set(n for n in names(up; all = true) if Base.ispublic(up, n))
        @test up_got ⊇ Set(
            [
                :juliaup_add_host!, :juliaup_default_host!, :juliaup_default_patch,
                :juliaup_status_lines, :juliaup_update_host!,
            ]
        )
        @test Base.ispublic(DistSSHRun, :rsync_send_list)
        @test !Base.isexported(DistSSHRun, :rsync_send_list)
    end

    @testset "a newline in a path is an error" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, "a\nb.txt"), "x\n")
            run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
            _ident!(tmp)
            _commit!(tmp, "nl")
            @test_throws ArgumentError DistSSHRun._rsync_send_list(tmp, DistSSHRun.resolve_pkg_env(tmp))
        end
    end
end
