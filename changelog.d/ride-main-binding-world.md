category: fixed

- `ride` looks up named functions in `Main` with `invokelatest` after runtime `eval` / prelude. A stale read warned on Julia 1.12+ and will error later. Pkg.test fails on that warning.