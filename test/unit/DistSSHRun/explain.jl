using Test

@testset "explain surfaces" begin
    @test DistSSHRun.join_explained_message("a", nothing) == "a"
    @test DistSSHRun.join_explained_message("a", "b") == "a\nb"

    @testset "surface / kind contracts" begin
        @test_throws ArgumentError DistSSHRun._normalize_hint_surface(:nope)
        @test_throws ArgumentError DistSSHRun.explain_no_hosts(; kind = :drive)
        cli_size = DistSSHRun.explain_no_hosts(; surface = :cli, kind = :size)
        @test occursin("size --help", cli_size)
        cli_collect = DistSSHRun.explain_no_hosts(; surface = :cli, kind = :collect)
        @test occursin("--collect-missing", cli_collect)
    end

    @testset "script not found" begin
        _with_tempdir() do tmp
            missing = joinpath(tmp, "nope.jl")
            msg = DistSSHRun.explain_script_not_found(missing, tmp; surface = :api)
            @test occursin("Script not found", msg)
            @test occursin(missing, msg)
            @test !occursin("install_demos", msg)

            demo = joinpath(tmp, "demos", "with_kit", "rho_sweep.jl")
            demo_msg = DistSSHRun.explain_script_not_found(demo, tmp; surface = :api)
            @test occursin("install_demos", demo_msg)

            headed = DistSSHRun.explain_script_not_found(
                demo, tmp; surface = :api, headline = "script not found: x",
            )
            @test startswith(headed, "script not found: x")
            @test occursin("DistSSHRun.install_demos(; family=", headed)

            kit_wrong = DistSSHRun.explain_script_not_found(
                joinpath(_kit_root(), "demos", "square_file.jl"),
                _kit_root(),
            )
            @test occursin("demos/with_kit/square_file.jl", kit_wrong)

            missing_kit = joinpath(tmp, "demos", "with_kit", "square_file.jl")
            cli = DistSSHRun.explain_script_not_found(missing_kit, tmp; surface = :cli)
            @test occursin("demo install", cli)
            @test !occursin("install_demos()", cli)
            api = DistSSHRun.explain_script_not_found(missing_kit, tmp; surface = :api)
            @test occursin("DistSSHRun.install_demos(; family=", api)
            @test !occursin("demo install", api)

            custom = joinpath(tmp, "demos", "with_kit", "rho_sweep.jl")
            @test occursin("./demos/ is missing", DistSSHRun.explain_script_not_found(custom, tmp))
            mkpath(joinpath(tmp, "demos", "with_kit"))
            after = DistSSHRun.explain_script_not_found(custom, tmp; surface = :api)
            @test occursin("no such file under ./demos/", after)
            @test occursin("DistSSHRun.list_demos()", after)
        end
    end

    @testset "hosts file" begin
        msg = DistSSHRun.explain_hosts_file_not_found("/no/hosts"; surface = :cli)
        @test occursin("hosts file not found", msg)
        @test occursin("--hosts-file", msg)
        msg_api = DistSSHRun.explain_hosts_file_not_found("/no/hosts"; surface = :api)
        @test occursin("hosts_file=", msg_api)

        empty_cli = DistSSHRun.explain_hosts_file_empty("/empty"; surface = :cli)
        @test occursin("command line", empty_cli)
        empty_api = DistSSHRun.explain_hosts_file_empty("/empty"; surface = :api)
        @test occursin("workers=", empty_api)
    end

    @testset "no hosts" begin
        @test occursin("workers=", DistSSHRun.explain_no_hosts(; surface = :api, kind = :ssh))
        @test occursin("--hosts-file", DistSSHRun.explain_no_hosts(; surface = :cli, kind = :ssh))
        @test occursin("collect!", DistSSHRun.explain_no_hosts(; surface = :api, kind = :collect))
        @test occursin("size!", DistSSHRun.explain_no_hosts(; surface = :api, kind = :size))
        @test occursin("pool!", DistSSHRun.explain_no_hosts(; surface = :api, kind = :pool))
        @test occursin(
            ":N",
            DistSSHRun.explain_bare_placement_tokens(["parent"]; surface = :cli),
        )
    end

    @testset "clone / probe / driver" begin
        @test occursin("repo=", DistSSHRun.explain_clone_repo_required(; surface = :api))
        @test occursin("--repo", DistSSHRun.explain_clone_repo_required(; surface = :cli))
        @test occursin("--repo", DistSSHRun.explain_clone_origin_missing(; surface = :cli))
        @test occursin("repo=", DistSSHRun.explain_clone_origin_missing(; surface = :api))
        @test occursin("--probe", DistSSHRun.explain_size_probe_not_found("x.jl"; surface = :cli))
        @test occursin("probe=", DistSSHRun.explain_size_probe_not_found("x.jl"; surface = :api))
        @test occursin("driver=", DistSSHRun.explain_pipeline_driver_missing(; surface = :api))
    end

    @testset "host tools" begin
        @test_throws ArgumentError DistSSHRun._normalize_host_tool("foo")
        @test DistSSHRun._normalize_host_tool("scp") == "scp"
        ssh = DistSSHRun.explain_host_tool_missing("ssh")
        @test occursin("ssh not found in PATH", ssh)
        @test occursin("OpenSSH", ssh)
        @test occursin("Requirements", ssh)
        @test DistSSHRun.explain_host_tool_missing("ssh"; surface = :cli) ==
            DistSSHRun.explain_host_tool_missing("ssh"; surface = :api)
        @test occursin("scp not found", DistSSHRun.explain_host_tool_missing("scp"))
        @test occursin("OpenSSH", DistSSHRun.explain_host_tool_missing("scp"))
        @test occursin("rsync", DistSSHRun.explain_host_tool_missing("rsync"))
        @test occursin("clone", DistSSHRun.explain_host_tool_missing("git"))
    end

    @testset "session wiring" begin
        _with_tempdir() do tmp
            session = DistSSHRun.KitSession(project = tmp, workers = String[], quiet = true)
            @test DistSSHRun.hint_surface(session) === :api
            @test session.cli_session.hint_surface === :api

            err = try
                with_kit_verbosity(:progress) do
                    DistSSHRun.sync!(session)
                end
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("workers=", sprint(showerror, err))
            @test occursin("Hint:", sprint(showerror, err))

            @test DistSSHRun.KitCliSession().hint_surface === :cli
        end
    end

    @testset "hosts file throws" begin
        _with_tempdir() do tmp
            missing = joinpath(tmp, "no-hosts.txt")
            err = try
                DistSSHRun.read_hosts_file_lines(missing; surface = :api)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("hosts_file=", sprint(showerror, err))

            empty = joinpath(tmp, "empty.txt")
            write(empty, "# only comments\n\n")
            err2 = try
                DistSSHRun.read_hosts_file_lines(empty; surface = :cli)
                nothing
            catch e
                e
            end
            @test err2 isa ArgumentError
            @test occursin("command line", sprint(showerror, err2))
        end
    end
end
