using Test
using Dates

# Oracle: slot plan, batch paths, julia resolve, missing-script surfaces, remote
# shell strings. Concurrent local `go!` is integration/go/overlap.jl.

@testset "go" begin
    @testset "_go_plan_slots" begin
        let s = DistSSHRun._go_plan_slots(String[])
            @test length(s) == 1
            @test s[1].kind === :parent
            @test s[1].label == "parent"
        end
        # `--repeat` pool helper: omit `:N` stays uncapped. go! / parse_go_args
        # reject the same token via `require_counted_placement_tokens`.
        let s = DistSSHRun._go_plan_slots(["parent"]; total = 1)
            @test length(s) == 1
            @test s[1].kind === :parent
            @test s[1].label == "parent"
        end
        @test_throws ArgumentError DistSSHRun.require_counted_placement_tokens(["parent"])
        let s = DistSSHRun._go_plan_slots(["child:local:2"])
            @test length(s) == 2
            @test s[1].kind === :child && s[1].label == "local-1"
            @test s[2].kind === :child && s[2].label == "local-2"
        end
        let s = DistSSHRun._go_plan_slots(["child:user@lab", "child:user@lab2:2"])
            @test length(s) == 3
            @test s[1].kind === :child && s[1].label == "user@lab"
            @test s[2].label == "user@lab2-1"
            @test s[3].label == "user@lab2-2"
        end
        let s = DistSSHRun._go_plan_slots(["parent:0", "child:h1", "child:h2"])
            @test length(s) == 2
            @test all(x -> x.kind === :child, s)
        end
        @test_throws ArgumentError DistSSHRun._go_plan_slots(["parent:0"])
        @test_throws ArgumentError DistSSHRun._go_plan_slots(["child:local:0"])
        @test_throws ArgumentError DistSSHRun._go_plan_slots(["child:local:-1"])
        @test DistSSHRun._go_sanitize_label("user@lab") == "user@lab"
        _with_tempdir() do proj::String
            in_batch = joinpath(proj, "scripts", ".distsshkit", "go", "job_1")
            in_slot = joinpath(in_batch, "h1-1")
            @test DistSSHRun._go_remote_slot_rel(proj, in_slot, in_batch, "h1-1") ==
                joinpath("scripts", ".distsshkit", "go", "job_1", "h1-1")
            _with_tempdir() do out_dir::String
                out_slot = joinpath(out_dir, "h1-1")
                rel = DistSSHRun._go_remote_slot_rel(proj, out_slot, out_dir, "h1-1")
                @test rel == joinpath(".distsshkit", "go", basename(out_dir), "h1-1")
                @test !occursin("..", rel)
            end
        end
        @test DistSSHRun._go_sanitize_label("a/b c") == "a_b_c"
        @test DistSSHRun._go_sanitize_label("***") == "_"
        err = try
            DistSSHRun._go_plan_slots(["lacal:0"])
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("child:NAME", sprint(showerror, err))
        let s = DistSSHRun._go_plan_slots(["parent:2"])
            @test length(s) == 2
            @test s[1].label == "parent-1"
            @test s[2].label == "parent-2"
        end
        let s = DistSSHRun._go_plan_slots(String[]; total = 4)
            @test length(s) == 4
            @test all(x -> x.kind === :parent, s)
            @test s[1].label == "parent-1"
            @test s[4].label == "parent-4"
        end
        let s = DistSSHRun._go_plan_slots(["parent:10"]; total = 3)
            @test length(s) == 3
        end
        @test_throws ArgumentError DistSSHRun._go_plan_slots(["parent:2"]; total = 3)
        let s = DistSSHRun._go_plan_slots(["child:h1"]; total = 2)
            @test length(s) == 2
            @test all(x -> x.kind === :child && x.host == "h1", s)
        end
        let s = DistSSHRun._go_plan_slots(["child:a", "child:b"]; total = 4)
            @test count(x -> x.host == "a", s) == 2
            @test count(x -> x.host == "b", s) == 2
        end
        let s = DistSSHRun._go_plan_slots(["child:a", "child:b"]; total = 3)
            @test count(x -> x.host == "a", s) == 2
            @test count(x -> x.host == "b", s) == 1
        end
        let s = DistSSHRun._go_plan_slots(["parent:1", "child:h1"]; total = 4)
            @test count(x -> x.kind === :parent, s) == 1
            @test count(x -> x.host == "h1", s) == 3
        end
        let pool = DistSSHRun._go_repeat_pool(["parent:1", "child:h1"])
            @test length(pool) == 2
            @test pool[1].role === :parent && pool[1].name == "parent"
            @test pool[2].role === :child && pool[2].name == "h1"
        end
        @test_throws ArgumentError DistSSHRun._go_plan_slots(
            ["parent:1", "child:parent:1"]; total = 2,
        )
        @test_throws ArgumentError DistSSHRun._go_plan_slots(["child:h1:1"]; total = 2)
        @test_throws ArgumentError DistSSHRun._go_plan_slots(String[]; total = 0)
        @test_throws ArgumentError DistSSHRun._go_plan_slots(String[]; total = true)
        @test occursin("root@", DistSSHRun._go_host_ssh_hint("192.0.2.11"))
        @test isempty(DistSSHRun._go_host_ssh_hint("root@192.0.2.11"))
    end

    @testset "_go_script_relpath" begin
        _with_tempdir() do proj
            nested = joinpath(proj, "demos", "job.jl")
            mkpath(dirname(nested))
            touch(nested)
            @test DistSSHRun._go_script_relpath(proj, nested) == joinpath("demos", "job.jl")
            @test_throws ArgumentError DistSSHRun._go_script_relpath(proj, "/tmp/outside.jl")
        end
    end

    @testset "_go_batch_output_dir" begin
        _with_tempdir() do proj
            script = joinpath(proj, "demos", "demo.jl")
            mkpath(dirname(script))
            touch(script)
            t = DateTime(2026, 8, 3, 13, 44, 28)
            batch = DistSSHRun._go_batch_output_dir(proj, script; now = t)
            @test batch == joinpath(proj, "demos", ".distsshkit", "go", "demo_20260803T134428Z")
            nested = joinpath(proj, "demos", "without_kit", "job.jl")
            mkpath(dirname(nested))
            touch(nested)
            nested_batch = DistSSHRun._go_batch_output_dir(proj, nested; now = t)
            @test nested_batch == joinpath(proj, "demos", "without_kit", ".distsshkit", "go", "job_20260803T134428Z")
            outside = joinpath(tempdir(), "outside-job.jl")
            write(outside, "nothing\n")
            other = DistSSHRun._go_batch_output_dir(proj, outside; now = t)
            @test other == joinpath(proj, ".distsshkit", "go", "outside-job_20260803T134428Z")
            @test isdir(batch)
            again = DistSSHRun._go_batch_output_dir(proj, script; now = t)
            @test again != batch
            @test isdir(again)
            @test startswith(basename(again), "demo_20260803T134428Z")
        end
    end

    @testset "_go_slot_exitcode" begin
        _with_tempdir() do d
            ssh0 = 0
            missing = joinpath(d, "no-such")
            @test DistSSHRun._go_slot_exitcode(ssh0, missing; scp_failed = false) == 0
            @test DistSSHRun._go_slot_exitcode(ssh0, missing; scp_failed = true) == 1
            @test DistSSHRun._go_slot_exitcode(7, missing; scp_failed = false) == 7
            ec = joinpath(d, "go.exitcode")
            write(ec, "3\n")
            @test DistSSHRun._go_slot_exitcode(ssh0, ec; scp_failed = true) == 1
            @test DistSSHRun._go_slot_exitcode(ssh0, ec; scp_failed = false) == 3
            write(ec, "0\n")
            @test DistSSHRun._go_slot_exitcode(ssh0, ec; scp_failed = true) == 1
        end
    end

    @testset "output_dir + collect_spec::String errors" begin
        _with_tempdir() do proj
            script = joinpath(proj, "job.jl")
            write(script, "nothing\n")
            err = try
                DistSSHRun.go!(
                    script,
                    ["parent:1"];
                    project = proj,
                    output_dir = joinpath(proj, "a"),
                    collect_spec = joinpath(proj, "b"),
                    quiet = true,
                )
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("not both", sprint(showerror, err))
        end
    end

    @testset "_go_resolve_julia" begin
        real = DistSSHRun._go_julia_exe()
        @test DistSSHRun._go_resolve_julia(nothing) == real
        @test DistSSHRun._go_resolve_julia("auto") == real
        @test DistSSHRun._go_resolve_julia(real) == real
        @test_throws ArgumentError DistSSHRun._go_resolve_julia("/no/such/julia-bin")
        @test_throws ArgumentError DistSSHRun._go_resolve_julia("auto"; host = "no-such-host.invalid")
    end

    @testset "a project file with no Manifest is refused" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"GoBare\"\n")
            script = joinpath(proj, "job.jl")
            write(script, "true\n")
            err = try
                DistSSHRun.go!(script, ["parent:1"]; project = proj, quiet = true, yes = true)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("No Manifest for ", err.msg)
            @test occursin("Pkg.resolve()", err.msg)
            @test !occursin("--help", err.msg)
        end
    end

    @testset "script not found surfaces" begin
        _with_tempdir() do tmp
            missing = joinpath(tmp, "demos", "with_kit", "rho_sweep.jl")
            err_api = try
                DistSSHRun.go!(missing, String[]; project = tmp)
                nothing
            catch e
                e
            end
            @test err_api isa ArgumentError
            @test occursin("DistSSHRun.install_demos(; family=", sprint(showerror, err_api))

            err_cli = try
                DistSSHRun.go!(missing, String[]; project = tmp, hint_surface = :cli)
                nothing
            catch e
                e
            end
            @test err_cli isa ArgumentError
            @test occursin("demo install", sprint(showerror, err_cli))
        end
    end

    @testset "_go_remote_slot_shell_inner" begin
        inner = DistSSHRun._go_remote_slot_shell_inner(
            "~/proj",
            "demos/output/go_sim/root@192.0.2.10-1",
            "demos/pi_file.jl",
            String[],
            "julia",
        )
        @test startswith(inner, "cd ")
        slot = "demos/output/go_sim/root@192.0.2.10-1"
        @test occursin("cd $(DistSSHRun._remote_shell_path_word("~/proj")) && mkdir -p $(DistSSHRun._remote_shell_path_word(slot))", inner)
        @test occursin("mkdir -p $(DistSSHRun._remote_shell_path_word(slot * "/.distsshkit"))", inner)
        @test occursin(">" * DistSSHRun._remote_shell_path_word(slot * "/julia.stdout.log"), inner)
        @test occursin("go.exitcode", inner)
        @test occursin("echo \$ec >", inner)

        spaced = DistSSHRun._go_remote_slot_shell_inner(
            "~/proj",
            "slot",
            "job.jl",
            String[],
            "/opt/Julia 1.12/bin/julia",
        )
        @test occursin(DistSSHRun._remote_shell_path_word("/opt/Julia 1.12/bin/julia"), spaced)

        with_args = DistSSHRun._go_remote_slot_shell_inner(
            "~/proj",
            "slot",
            "job.jl",
            ["8", "a b"],
            "julia",
        )
        @test occursin("env -u JULIA_PROJECT", with_args)
        @test occursin("JULIA_LOAD_PATH=", with_args)
        @test occursin("--project=.", with_args)
        @test occursin("--startup-file=no", with_args)
        @test occursin(DistSSHRun._remote_shell_path_word("job.jl"), with_args)
        @test occursin(DistSSHRun._remote_shell_path_word("8"), with_args)
        @test occursin(DistSSHRun._remote_shell_path_word("a b"), with_args)
        @test occursin(
            DistSSHRun._remote_shell_path_word("slot/.distsshkit/provenance-slot.jl"),
            with_args,
        )
        @test occursin("DISTSSH_PROVENANCE_SLOT", with_args)

        withenv("DISTSSHKIT_JOB_ID" => "repro-1") do
            tagged = DistSSHRun._go_remote_slot_shell_inner(
                "~/proj",
                "slot",
                "job.jl",
                String[],
                "julia",
            )
            @test occursin(" -L ", tagged)
            @test occursin("distsshkit-job:repro-1", tagged)
            @test occursin("printf '%s\\n' '#distsshkit-job:repro-1'", tagged)
            @test !occursin("--eval=", tagged)
            @test !occursin("include(popfirst!(ARGS))", tagged)
        end
    end

    @testset "job_id slot programfile + ARGS" begin
        _with_tempdir() do d
            write(joinpath(d, "Project.toml"), "[deps]\n")
            mark = joinpath(d, "RAN")
            argsf = joinpath(d, "ARGS")
            envf = joinpath(d, "ENVJOB")
            progf = joinpath(d, "PROGRAM")
            script = joinpath(d, "mark.jl")
            write(
                script, """
                write($(repr(mark)), "yes")
                write($(repr(argsf)), join(ARGS, '\\n'))
                write($(repr(envf)), get(ENV, "DISTSSHKIT_JOB_ID", ""))
                write($(repr(progf)), PROGRAM_FILE)
                """
            )
            slot = joinpath(d, "slot")
            withenv("DISTSSHKIT_JOB_ID" => "repro-1") do
                r = DistSSHRun._go_run_local_slot!(
                    d, script, ["a", "b c"], slot; quiet = true,
                )
                @test r.ok
            end
            @test isfile(mark)
            @test split(read(argsf, String), '\n'; keepempty = false) == ["a", "b c"]
            @test strip(read(envf, String)) == "repro-1"
            @test abspath(strip(read(progf, String))) == abspath(script)
            @test isfile(joinpath(slot, DistSSHRun.kit_job_pkill_pattern("repro-1")))
            snap = DistSSHRun.TOML.parsefile(
                joinpath(slot, ".distsshkit", "provenance-slot.toml"),
            )
            @test snap["version"] == string(VERSION)
        end
    end

    @testset "report_go_errors" begin
        ok = DistSSHRun.GoResult(true, nothing, nothing, nothing, "job.jl", "/out")
        @test DistSSHRun.report_go_errors(ok)
        bad = DistSSHRun.GoResult(
            false,
            DistSSHRun.SyncResult(false, [DistSSHRun.HostResult("h1", false, "pull failed")], false),
            DistSSHRun.DriveResult(false, 2),
            DistSSHRun.CollectResult(false, 1),
            "job.jl",
            "/tmp/go-out";
            failed_step = "run",
        )
        buf = IOBuffer()
        @test !DistSSHRun.report_go_errors(bad; io = buf)
        txt = String(take!(buf))
        @test occursin("go failed at step: run", txt)
        @test occursin("output: /tmp/go-out", txt)
        @test occursin("sync h1: pull failed", txt)
        @test occursin("run exit 2", txt)
        @test occursin("collect exit 1", txt)
        kr = DistSSHRun.kit_run_result(bad)
        @test kr.kind === :go
        mktempdir() do rd
            withenv(DistSSHRun.DISTSSHKIT_RUN_DIR_ENV => rd) do
                positional = DistSSHRun.GoResult(
                    false, nothing, nothing, nothing, "job.jl", "/out", "sync",
                )
                @test positional.failed_step == "sync"
                @test positional.run_dir == DistSSHRun.kit_run_dir()
            end
        end
        @test kr.output_dir == "/tmp/go-out"
        @test kr.exit_code == 2
        @test !DistSSHRun.report_run_errors(bad; io = IOBuffer())
    end

    @testset "quiet suppresses Log file on stdout" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"GoQuietLog\"\n")
            write(joinpath(proj, "Manifest.toml"), "# lock\n")
            script = joinpath(proj, "job.jl")
            write(script, "true\n")
            with_kit_verbosity(:verbose) do
                out, _ = _capture_stdio() do _, _
                    DistSSHRun.go!(
                        script, ["parent:1"];
                        project = proj, quiet = true, yes = true,
                    )
                end
                @test !occursin("Log file:", out)
            end
            r = redirect_stdout(devnull) do
                DistSSHRun.go!(
                    script, ["parent:1"];
                    project = proj, quiet = true, yes = true,
                    original_args = ["parent:1", "job.jl"],
                )
            end
            @test r.ok
            logs = filter(n -> startswith(n, "go_") && endswith(n, ".log"), readdir(r.output_dir))
            @test length(logs) == 1
            body = read(joinpath(r.output_dir, only(logs)), String)
            @test occursin("Subcommand args: go", body)
            @test occursin("Julia binary:", body)
            @test occursin("DistSSHRun:", body)
            @test occursin("Project:", body)
            @test occursin("Slots: 1", body)
            prog = read(joinpath(r.output_dir, "kit.progress"), String)
            @test occursin("label=ready", prog)
            @test occursin("label=sync", prog)
            @test occursin("label=run", prog)
            @test occursin("label=collect", prog)
            run_mark = findfirst("step kind=go label=run", prog)
            collect_mark = findfirst("step kind=go label=collect", prog)
            @test run_mark !== nothing && collect_mark !== nothing
            @test first(run_mark) < first(collect_mark)
            run_span = findlast("label=parent/run", prog)
            @test run_span !== nothing
            @test first(run_span) < first(collect_mark)
        end
    end

    @testset "DISTSSHKIT_HOSTS_FILE not reapplied when workers set" begin
        _with_tempdir() do proj
            script = joinpath(proj, "job.jl")
            write(script, "true\n")
            hf = joinpath(proj, "hosts")
            write(hf, "child:no-such-host.invalid:1\n")
            withenv("DISTSSHKIT_HOSTS_FILE" => hf) do
                redirect_stdout(devnull) do
                    r = DistSSHRun.go!(
                        script, ["parent:1"];
                        project = proj, quiet = true, yes = true,
                    )
                    @test r.ok
                end
            end
        end
    end

    @testset "later succeeding slot does not mask earlier failure" begin
        _with_tempdir() do proj::String
            script = joinpath(proj, "job.jl")
            write(
                script,
                """
                slot = basename(get(ENV, "DISTRIBUTED_OUTPUT_DIR", ""))
                if endswith(slot, "-1")
                    exit(2)
                else
                    sleep(0.15)
                    exit(0)
                end
                """,
            )
            r = redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    DistSSHRun.go!(
                        script, ["parent:2"];
                        project = proj, quiet = true, yes = true,
                    )
                end
            end
            @test !r.ok
            @test r.run.ok == false
            @test r.run.exit_code == 2
        end
    end

    @testset "_last_trace_location" begin
        colored = "eval: \e[90m#= script.jl:4 =#\e[39m\n"
        @test DistSSHRun._last_trace_location(colored) == "script.jl:4"
        plain = "eval: #= /tmp/a.jl:2 =#\nhi\neval: #= /tmp/a.jl:9 =#\n"
        @test DistSSHRun._last_trace_location(plain) == "/tmp/a.jl:9"
        full = "eval: \$(Expr(:toplevel, :(#= virt.jl:3 =#), :(f())))\n"
        @test DistSSHRun._last_trace_location(full) == "virt.jl:3"
        marked = "eval: #= /tmp/distsshkit-job:repro-1:1 =#\neval: #= job.jl:2 =#\n"
        @test DistSSHRun._last_trace_location(marked) == "job.jl:2"
        @test DistSSHRun._last_trace_location("eval: #= /tmp/distsshkit-job:repro-1:1 =#\n") === nothing
        @test DistSSHRun._last_trace_location("hello\nno trace\n") === nothing
    end

    @testset "failed slot names last top-level" begin
        _with_tempdir() do proj
            script = joinpath(proj, "job.jl")
            write(
                script,
                """
                Base.TRACE_EVAL = :loc
                println("hello")
                error("boom")
                """,
            )
            err_path, err_io = mktemp()
            r = try
                redirect_stderr(err_io) do
                    redirect_stdout(devnull) do
                        DistSSHRun.go!(
                            script, ["parent:1"];
                            project = proj, quiet = true, yes = true,
                        )
                    end
                end
            finally
                close(err_io)
            end
            txt = read(err_path, String)
            @test !r.ok
            @test occursin("last top-level:", txt)
            @test occursin("job.jl:", txt)
        end
    end

    @testset "non-empty output directory" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"GoDirty\"\n")
            write(joinpath(proj, "Manifest.toml"), "# lock\n")
            script = joinpath(proj, "job.jl")
            write(script, "println(\"ran\")\n")
            dirty = joinpath(proj, "batch")
            mkdir(dirty)
            write(joinpath(dirty, "stale.txt"), "old\n")
            err = try
                DistSSHRun.go!(
                    script;
                    project = proj,
                    output_dir = dirty,
                    quiet = true,
                    yes = true,
                    hint_surface = :cli,
                )
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            err isa ArgumentError || error("expected ArgumentError")
            @test occursin(dirty, err.msg)
            @test occursin("stale.txt", err.msg)
            @test occursin("Run `julia -m DistSSHKit help go` for flags.", err.msg)
            @test !occursin("--help", err.msg)
            @test isfile(joinpath(dirty, "stale.txt"))
            @test !isfile(joinpath(dirty, ".kit.lock"))
            spec_err = try
                DistSSHRun.go!(
                    script;
                    project = proj,
                    collect_spec = dirty,
                    quiet = true,
                    yes = true,
                    hint_surface = :api,
                )
                nothing
            catch e
                e
            end
            @test spec_err isa ArgumentError
            spec_err isa ArgumentError || error("expected ArgumentError")
            @test occursin("Omit output_dir or pass an empty directory.", spec_err.msg)
            empty_dir = joinpath(proj, "empty-batch")
            mkdir(empty_dir)
            r = redirect_stdout(devnull) do
                DistSSHRun.go!(
                    script;
                    project = proj,
                    output_dir = empty_dir,
                    quiet = true,
                    yes = true,
                )
            end
            @test r.ok
            @test r.output_dir == DistSSHRun.canonical_local_path(empty_dir)
            code, err_txt = mktemp() do err_path, err_io
                status = redirect_stdout(devnull) do
                    redirect_stderr(err_io) do
                        withenv(
                            "DISTRIBUTED_PROJECT_ROOT" => proj,
                            "DISTSSHKIT_CLI_SUBCOMMAND_DONE" => "",
                        ) do
                            DistSSHRun.main(["go", "-q", "--output-dir", dirty, script])
                        end
                    end
                end
                flush(err_io)
                return status, read(err_path, String)
            end
            @test code == 1
            @test occursin("Error:", err_txt)
            @test occursin("stale.txt", err_txt)
            @test occursin("help go", err_txt)
            @test !occursin("--help", err_txt)
        end
    end

    @testset "early go! exit drains deferred input hashes" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"GoHashDrain\"\n")
            write(joinpath(proj, "Manifest.toml"), "# lock\n")
            script = joinpath(proj, "job.jl")
            write(script, "true\n")
            out = joinpath(proj, "out")
            DistSSHRun.await_declared_input_hashes!()
            try
                task = @async nothing
                lock(DistSSHRun._PENDING_INPUT_HASH_LOCK) do
                    push!(DistSSHRun._PENDING_INPUT_HASH_TASKS, task)
                end
                err = redirect_stderr(devnull) do
                    redirect_stdout(devnull) do
                        try
                            DistSSHRun.go!(
                                script,
                                ["child:user@hash-drain.test:1"];
                                project = proj,
                                output_dir = out,
                                sync = :not_a_mode,
                                quiet = true,
                                yes = true,
                            )
                            nothing
                        catch e
                            e
                        end
                    end
                end
                @test err isa ArgumentError
                @test occursin("sync! mode must be", sprint(showerror, err))
                @test isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)
                @test !isfile(joinpath(out, ".kit.lock"))

                bad = @async error("hash failed early")
                lock(DistSSHRun._PENDING_INPUT_HASH_LOCK) do
                    push!(DistSSHRun._PENDING_INPUT_HASH_TASKS, bad)
                end
                out2 = joinpath(proj, "out-hash-fail")
                err2 = redirect_stderr(devnull) do
                    redirect_stdout(devnull) do
                        try
                            DistSSHRun.go!(
                                script,
                                ["child:user@hash-drain.test:1"];
                                project = proj,
                                output_dir = out2,
                                sync = :not_a_mode,
                                quiet = true,
                                yes = true,
                            )
                            nothing
                        catch e
                            e
                        end
                    end
                end
                @test err2 isa TaskFailedException
                @test isempty(DistSSHRun._PENDING_INPUT_HASH_TASKS)
                @test !isfile(joinpath(out2, ".kit.lock"))
            finally
                try
                    DistSSHRun.await_declared_input_hashes!()
                catch
                end
            end
        end
    end
end
