"""
Worker sizing.

Names marked `public` are a contract inside the DistSSH family. A 0.x patch
does not change them.
"""
module DistSSHSize

using ..DistSSHBase

let _size_body = joinpath(@__DIR__, "..", "..", "lib", "DistSSHSize", "src", "body.jl")
    isfile(_size_body) || error(
        "DistSSHRun: $_size_body is missing. Copy the whole DistSSHRun package directory, including lib/, not only src/.",
    )
end
include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHSize", "src", "body.jl"))

end # module DistSSHSize
