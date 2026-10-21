"""
Parse `julia --version`, keeping prerelease and build.

`julia version 1.14.0-alpha1` is `v"1.14.0-alpha1"`. Unreadable text is `nothing`.
[`parse_julia_version`](@ref) still returns major.minor.patch only.
"""
function parse_julia_version_full(version_output::AbstractString)::Union{Nothing, VersionNumber}
    m = match(r"julia version (\d+\.\d+\.\d+(?:[-+][^\s]+)?)", String(version_output))
    m === nothing && return nothing
    cap = m.captures[1]
    cap isa AbstractString || return nothing
    try
        return VersionNumber(String(cap))
    catch
        return nothing
    end
end

"""
Remote `julia --version`, keeping prerelease and build.

Same host and path as [`get_remote_julia_version`](@ref). `nothing` on failure.
"""
function get_remote_julia_version_full(host::String, julia_path::AbstractString)::Union{Nothing, VersionNumber}
    try
        return parse_julia_version_full(_remote_julia_version_output(host, julia_path))
    catch
        return nothing
    end
end
