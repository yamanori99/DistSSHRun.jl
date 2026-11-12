# Opt-in SSH checks. SIGKILL detached-drive worker reap (Distributed EOF exit 1,
# not heartbeat exit 75) lives in test/e2e.jl. SIGSTOP/SIGKILL heartbeat timing
# SSH E2E is a separate PR.
# This file only confirms sshd is reachable when DISTSSH_SSH_E2E=1.

@testset "ssh reachable" begin
    ssh = Sys.which("ssh")
    @test ssh !== nothing
    proc = run(pipeline(`$ssh -o BatchMode=yes -o ConnectTimeout=5 localhost true`; stdout = devnull, stderr = devnull); wait = false)
    wait(proc)
    @test success(proc)
end
