category: fixed

- `ride!` no longer treats `workers() = 4`, `Foo.pmap`, `Iterators.map`, `Threads.@spawn` after `using Base.Threads: @spawn`, `Int[...]`, `map(f, a, b)`, or `map(xs) do` as Distributed vocabulary. `Distributed.@everywhere` and `Distributed.pmap` still reject. A file `Meta.parseall` cannot parse still fails `ride!`.
