category: changed

- `terminate!` and `terminate_run!` now `pkill` local go head slots that outlive the detached kit child (Julia 1.14), scoped to this run's `go-handshake.jl` paths under kit directories. Patterns are POSIX ERE literals with a `/` after the kit root, so a sibling directory is not matched.
