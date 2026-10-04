# Load this checkout when `--project` is the user's app, not DistSSHRun.
# `using DistSSHBase` inside the included module needs the checkout environment
# on LOAD_PATH. A registry install takes the `import` above this and never gets here.

function _include_checkout_run()
    root = normpath(joinpath(@__DIR__, "..", ".."))
    root in LOAD_PATH || push!(LOAD_PATH, root)
    include(joinpath(@__DIR__, "..", "DistSSHRun.jl"))
    return nothing
end
