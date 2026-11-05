category: fixed

- `plan` and `ride` no longer treat `workers() = 4`, `Foo.pmap`, `Iterators.map`, `Threads.@spawn` after `using Base.Threads: @spawn`, `Int[...]`, `map(f, a, b)`, or `map(xs) do` as Distributed or as a `ride` rewrite. `Distributed.@everywhere` and `Distributed.pmap` still select `drive`. A file `Meta.parseall` cannot parse is `ok=false`. A `:candidate` finding is a form `ride` rewrites.

