using Test

if !isdefined(@__MODULE__, :B)
    const B = DistSSHRun.DistSSHBase
end

@testset "remote shell quotes metacharacters" begin
    @test B._remote_shell_path_word("/srv/x;id") == "'/srv/x;id'"
    @test B._remote_shell_path_word("~/Repo") == "~/'Repo'"
    @test B._remote_shell_path_word("~/a/b c") == "~/'a/b c'"
    @test B._ssh_host_args("host", "true") == ["--", "host", "true"]
end

@testset "remote path forbidden" begin
    @test B._remote_path_forbidden("~/../u")
    @test B._remote_path_forbidden("/a/../b")
    @test !B._remote_path_forbidden("~/a/proj")
end
