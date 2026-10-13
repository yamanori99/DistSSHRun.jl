"""juliaup verbs on hosts (`up add`, `up default`, `up update`, `up status`)."""
module DistSSHUp

using ..DistSSHBase

include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHUp", "src", "body.jl"))

end # module DistSSHUp
