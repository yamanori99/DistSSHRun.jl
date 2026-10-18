# Driver for the drive Ctrl-C test. Touches the marker once `main` runs,
# then keeps every worker busy until the test sends SIGINT.
using Distributed

function main()
    touch(ENV["DISTSSHKIT_TEST_SIGINT_MARKER"])
    pmap(_ -> (sleep(120); 1), 1:nworkers())
    return nothing
end
