# Long enough for E2E to kill or terminate! a detached SSH drive.
using Distributed

function main()
    pmap(_ -> (sleep(30); 1), 1:nworkers())
    return nothing
end
