#!/usr/bin/env julia
# Independent indexed `for` (`dest[i] = …`).
#
#   julia --project=. -m DistSSHRun ride parent:2 demos/ride/for_loop.jl

xs = 1:4
ys = similar(collect(xs))
for i in eachindex(xs)
    ys[i] = xs[i] * xs[i]
end
println(join(ys, ","))
