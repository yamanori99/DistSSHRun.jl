# Opt-in SSH checks. Drive SIGKILL/SIGSTOP coverage lives in test/e2e.jl.
# This file only confirms sshd is reachable when DISTSSH_SSH_E2E=1.

@testset "ssh reachable" begin
    ssh = Sys.which("ssh")
    @test ssh !== nothing
    proc = run(pipeline(`$ssh -o BatchMode=yes -o ConnectTimeout=5 localhost true`; stdout = devnull, stderr = devnull); wait = false)
    wait(proc)
    @test success(proc)
end
