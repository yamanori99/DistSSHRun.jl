using Test

@testset "wait_seconds" begin
    @test DistSSHBase.wait_seconds(:child_reply, 300) == 300.0
    @test DistSSHBase.wait_seconds(:go_job, 120) == 120.0
    @test DistSSHBase.wait_seconds(:drive_job, 360) == 360.0
    @test DistSSHBase.wait_seconds(:stop_grace, 5) == 5.0
    @test DistSSHBase.wait_seconds(:sigint_grace, 20) == 20.0
    @test DistSSHBase.wait_seconds(:e2e_stop, 10) == 10.0
    @test DistSSHBase.wait_seconds(:ssh_connect, 10) == 10.0
    @test DistSSHBase.wait_seconds(:peer_silent, 600) == 600.0
    @test DistSSHBase.wait_seconds(:until_exit, 1) === Inf
    @test_throws ArgumentError DistSSHBase.wait_seconds(:not_a_wait, 1)

    withenv("DISTSSHKIT_WAIT_SCALE" => "2") do
        @test DistSSHBase.wait_seconds(:child_reply, 300) == 600.0
        @test DistSSHBase.wait_seconds(:go_job, 120) == 240.0
        @test DistSSHBase.wait_seconds(:stop_grace, 5) == 5.0
        @test DistSSHBase.wait_seconds(:ssh_connect, 10) == 10.0
        @test DistSSHBase.wait_seconds(:until_exit, 3) === Inf
    end

    withenv("DISTSSHKIT_WAIT_SCALE" => "0") do
        @test DistSSHBase.wait_seconds(:child_reply, 300) == 300.0
    end
    withenv("DISTSSHKIT_WAIT_SCALE" => "nope") do
        @test DistSSHBase.wait_seconds(:drive_job, 360) == 360.0
    end

    withenv("DISTSSHKIT_WAIT_SCALE" => "2", "DISTSSHKIT_WAIT_CHILD_REPLY" => "9") do
        @test DistSSHBase.wait_seconds(:child_reply, 300) == 9.0
        @test DistSSHBase.wait_seconds(:go_job, 120) == 240.0
    end
    withenv("DISTSSHKIT_WAIT_CHILD_REPLY" => "soon") do
        @test DistSSHBase.wait_seconds(:child_reply, 300) == 300.0
    end
    withenv("DISTSSHKIT_WAIT_STOP_GRACE" => "1.5") do
        @test DistSSHBase.wait_seconds(:stop_grace, 5) == 1.5
    end
end
