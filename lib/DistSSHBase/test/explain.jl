using Test

@testset "explain surfaces" begin
    @test DistSSHBase.join_explained_message("a", nothing) == "a"
    @test DistSSHBase.join_explained_message("a", "b") == "a\nb"

    @testset "surface / kind contracts" begin
        @test_throws ArgumentError DistSSHBase._normalize_hint_surface(:nope)
        @test_throws ArgumentError DistSSHBase.explain_no_hosts(; kind = :drive)
        cli_size = DistSSHBase.explain_no_hosts(; surface = :cli, kind = :size)
        @test occursin("size --help", cli_size)
        cli_collect = DistSSHBase.explain_no_hosts(; surface = :cli, kind = :collect)
        @test occursin("--collect-missing", cli_collect)
    end

    @testset "hosts file" begin
        msg = DistSSHBase.explain_hosts_file_not_found("/no/hosts"; surface = :cli)
        @test occursin("hosts file not found", msg)
        @test occursin("--hosts-file", msg)
        msg_api = DistSSHBase.explain_hosts_file_not_found("/no/hosts"; surface = :api)
        @test occursin("hosts_file=", msg_api)

        empty_cli = DistSSHBase.explain_hosts_file_empty("/empty"; surface = :cli)
        @test occursin("command line", empty_cli)
        empty_api = DistSSHBase.explain_hosts_file_empty("/empty"; surface = :api)
        @test occursin("workers=", empty_api)
    end

    @testset "no hosts" begin
        @test occursin("workers=", DistSSHBase.explain_no_hosts(; surface = :api, kind = :ssh))
        @test occursin("--hosts-file", DistSSHBase.explain_no_hosts(; surface = :cli, kind = :ssh))
        @test occursin("collect!", DistSSHBase.explain_no_hosts(; surface = :api, kind = :collect))
        @test occursin("size!", DistSSHBase.explain_no_hosts(; surface = :api, kind = :size))
        @test occursin("pool!", DistSSHBase.explain_no_hosts(; surface = :api, kind = :pool))
        @test occursin(
            ":N",
            DistSSHBase.explain_bare_placement_tokens(["parent"]; surface = :cli),
        )
    end

    @testset "clone / probe / driver" begin
        @test occursin("repo=", DistSSHBase.explain_clone_repo_required(; surface = :api))
        @test occursin("--repo", DistSSHBase.explain_clone_repo_required(; surface = :cli))
        @test occursin("--repo", DistSSHBase.explain_clone_origin_missing(; surface = :cli))
        @test occursin("repo=", DistSSHBase.explain_clone_origin_missing(; surface = :api))
        @test occursin("--probe", DistSSHBase.explain_size_probe_not_found("x.jl"; surface = :cli))
        @test occursin("probe=", DistSSHBase.explain_size_probe_not_found("x.jl"; surface = :api))
        @test occursin("driver=", DistSSHBase.explain_pipeline_driver_missing(; surface = :api))
    end

    @testset "host tools" begin
        @test_throws ArgumentError DistSSHBase._normalize_host_tool("foo")
        @test DistSSHBase._normalize_host_tool("scp") == "scp"
        ssh = DistSSHBase.explain_host_tool_missing("ssh")
        @test occursin("ssh not found in PATH", ssh)
        @test occursin("OpenSSH", ssh)
        @test occursin("DistSSHKit", ssh)
        @test occursin("Requirements", ssh)
        DistSSHBase.with_cli_entry(:DistSSHQueue) do
            queued = DistSSHBase.explain_host_tool_missing("ssh")
            @test occursin("DistSSHQueue", queued)
        end
        @test DistSSHBase.explain_host_tool_missing("ssh"; surface = :cli) ==
            DistSSHBase.explain_host_tool_missing("ssh"; surface = :api)
        @test occursin("scp not found", DistSSHBase.explain_host_tool_missing("scp"))
        @test occursin("OpenSSH", DistSSHBase.explain_host_tool_missing("scp"))
        @test occursin("rsync", DistSSHBase.explain_host_tool_missing("rsync"))
        @test occursin("clone", DistSSHBase.explain_host_tool_missing("git"))
    end

    @testset "hosts file throws" begin
        _with_tempdir() do tmp
            missing = joinpath(tmp, "no-hosts.txt")
            @test_throws ["ArgumentError:", "hosts_file="] DistSSHBase.read_hosts_file_lines(
                missing; surface = :api,
            )

            empty = joinpath(tmp, "empty.txt")
            write(empty, "# only comments\n\n")
            @test_throws ["ArgumentError:", "command line"] DistSSHBase.read_hosts_file_lines(
                empty; surface = :cli,
            )
        end
    end
end
