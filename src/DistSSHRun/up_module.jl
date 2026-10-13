"""juliaup verbs on hosts (`up add`, `up default`, `up update`, `up status`)."""
module DistSSHUp

using ..DistSSHBase

let _up_body = joinpath(@__DIR__, "..", "..", "lib", "DistSSHUp", "src", "body.jl")
    isfile(_up_body) || error(
        "DistSSHRun: $_up_body is missing. Copy the whole DistSSHRun package directory, including lib/, not only src/.",
    )
    include(_up_body)
end

end # module DistSSHUp
