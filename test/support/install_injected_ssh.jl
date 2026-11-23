# Child `julia -m DistSSHRun` does not load test/support.jl. Install the
# DistSSHBase SSH/juliaup doubles so DISTSSH_TEST_SSH in the child env works.
using DistSSHRun
include(joinpath(pkgdir(DistSSHRun), "lib", "DistSSHBase", "test", "support.jl"))
