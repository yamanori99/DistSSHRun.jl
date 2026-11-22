category: skip
no user-facing change

- CI unit and integration jobs on Ubuntu and macOS (Julia 1.13 and 1.14-pre) run `test/parallel.jl` with one worker per CPU thread. Main-push coverage still uses serial `Pkg.test()`.
