# Oracle: argv builders and forwarded opts only (no E2E worker launch or file transfer).
using Test
using TOML

const _B = DistSSHRun.DistSSHBase

function _placement_ssh_p_flag(host::AbstractString)::Vector{String}
    opts = _B.ssh_connection_ssh_opts(host)
    idx = findfirst(==("-p"), opts)
    idx === nothing && return String[]
    return opts[idx:(idx + 1)]
end

withenv(
    "DISTRIBUTED_SSH_OPTS" => nothing,
    "DISTSSH_TEST" => nothing,
    "DISTSSH_TEST_SSH" => nothing,
) do
    @testset "placement ssh argv surfaces (#505)" begin
        @testset "explicit port only on argv when token names one" begin
            with_port = "alice@lab:2222"
            plain = "alice@lab"
            @test _placement_ssh_p_flag(with_port) == ["-p", "2222"]
            @test isempty(_placement_ssh_p_flag(plain))
            withenv("DISTRIBUTED_SSH_OPTS" => "-p 9999 -o Port=8888") do
                @test _placement_ssh_p_flag(with_port) == ["-p", "2222"]
                env_plain = _placement_ssh_p_flag(plain)
                @test env_plain == ["-p", "9999"]
            end
        end

        @testset "drive worker sshflags share ssh_connection_ssh_opts" begin
            host = "alice@lab:2222"
            exec = Cmd(_B.ssh_connection_ssh_opts(host)).exec
            @test "-p" in exec
            @test "2222" in exec
            @test !("-p" in Cmd(_B.ssh_connection_ssh_opts("alice@lab")).exec)
        end

        @testset "go ship and deploy record scp prefixes match scp_connection_argv" begin
            host = "user@child:2222"
            scp_prefix = _B.scp_connection_argv(host)
            @test scp_prefix[(end - 1):end] == ["-P", "2222"]
            upload = DistSSHRun._deploy_record_scp_upload_argv(host, "/remote/x", "/local/x")
            @test upload[1:length(scp_prefix)] == scp_prefix
            @test !("-P" in _B.scp_connection_argv("user@child"))
        end

        @testset "setup-style remote session and interrupt phase use the same port" begin
            host = "alice@lab:2222"
            session = _B._ssh_remote_session_argv(host, "true")
            @test findfirst(==("-p"), session) !== nothing
            @test !("-p" in _B._ssh_remote_session_argv("alice@lab", "true"))
            _with_ssh_stub_in_path() do
                phase = DistSSHRun._ssh_phase_cmd(host, "true")
                @test "-p" in phase.exec
                @test !("-p" in DistSSHRun._ssh_phase_cmd("alice@lab", "true").exec)
                withenv("DISTRIBUTED_SSH_OPTS" => "-p 2200") do
                    dup = DistSSHRun._ssh_phase_cmd(host, "true")
                    @test count(==("-p"), dup.exec) == 1
                    @test "2222" in dup.exec
                end
            end
        end

        @testset "TOML port field becomes the same endpoint as inline :port" begin
            mktempdir() do tmp
                path = joinpath(tmp, "hosts.toml")
                write(
                    path,
                    """
                    [[hosts]]
                    name = "lab"
                    user = "alice"
                    port = 2222
                    workers = 2
                    """,
                )
                entry = _B.read_toml_host_entries(path)[1]
                dest = _B.toml_host_ssh_dest(entry)
                @test dest == "alice@lab:2222"
                @test _placement_ssh_p_flag(dest) == ["-p", "2222"]
            end
        end
    end
end
