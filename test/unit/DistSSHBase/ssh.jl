using Test

let _BASE = DistSSHRun.DistSSHBase
    @testset "remote shell quotes metacharacters" begin
        @test _BASE._remote_shell_path_word("/srv/x;id") == "'/srv/x;id'"
        @test _BASE._remote_shell_path_word("~/Repo") == "~/'Repo'"
        @test _BASE._remote_shell_path_word("~/a/b c") == "~/'a/b c'"
        @test _BASE._ssh_host_args("host", "true") == ["--", "host", "true"]
    end

    @testset "remote path forbidden" begin
        @test _BASE._remote_path_forbidden("~/../u")
        @test _BASE._remote_path_forbidden("/a/../b")
        @test !_BASE._remote_path_forbidden("~/a/proj")
    end
end
