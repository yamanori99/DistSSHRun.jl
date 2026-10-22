"""`v` without its build (`+0.aarch64` and the like). Prerelease stays."""
function _julia_version_without_build(v::VersionNumber)::VersionNumber
    return VersionNumber(v.major, v.minor, v.patch, v.prerelease, ())
end

"""Compare two Julia versions and classify the difference.

`:none` when major.minor.patch and prerelease match. A build-only difference is `:none`.
`:minor` when major.minor differs. `:patch` when only the patch differs.
`:prerelease` when major.minor.patch match and the prerelease does not.
"""
function julia_version_mismatch_kind(
        local_version::VersionNumber,
        remote_version::VersionNumber,
    )::Symbol
    local_version = _julia_version_without_build(local_version)
    remote_version = _julia_version_without_build(remote_version)
    if remote_version.major != local_version.major || remote_version.minor != local_version.minor
        return :minor
    elseif remote_version.patch != local_version.patch
        return :patch
    elseif remote_version.prerelease != local_version.prerelease
        return :prerelease
    end
    return :none
end

"""Oldest `juliaup --version` this package will run. Older builds are an error."""
const JULIAUP_MIN = v"1.22.0"

"""`Juliaup x.y.z` from `juliaup --version`, or `nothing`."""
function _juliaup_version(text::AbstractString)::Union{Nothing, VersionNumber}
    line = ""
    for row in eachsplit(String(text), '\n'; keepempty = false)
        line = strip(row)
        isempty(line) || break
    end
    m = match(r"^Juliaup\s+(\d+\.\d+(?:\.\d+)?)\b", line)
    m === nothing && return nothing
    cap = m.captures[1]
    cap === nothing && return nothing
    return VersionNumber(String(cap))
end

"""Error when `ver` is missing or older than [`JULIAUP_MIN`](@ref)."""
function _reject_old_juliaup(ver::Union{Nothing, VersionNumber}, seen::AbstractString)
    if ver === nothing
        line = ""
        for row in eachsplit(String(seen), '\n'; keepempty = false)
            line = strip(row)
            isempty(line) || break
        end
        shown = isempty(line) ? "empty" : line
        error("juliaup --version unreadable: $shown")
    end
    floor = "$(JULIAUP_MIN.major).$(JULIAUP_MIN.minor)"
    ver < JULIAUP_MIN && error("juliaup $ver is older than $floor")
    return nothing
end

"""Channel string for juliaup from a Julia `VersionNumber`.

A release is `\"1.13\"`. `1.14.0-DEV` is `\"1.14-nightly\"`.
Another prerelease keeps its name: `1.13.0-rc1`.
"""
function juliaup_channel(v::VersionNumber = VERSION)::String
    pre = v.prerelease
    isempty(pre) && return "$(v.major).$(v.minor)"
    head = first(pre)
    if !(head isa Integer) && String(head) == "DEV"
        return "$(v.major).$(v.minor)-nightly"
    end
    parts = map(pre) do piece
        piece isa Integer ? string(Int(piece)) : String(piece)
    end
    return "$(v.major).$(v.minor).$(v.patch)-$(join(parts, "."))"
end

"""True when `remote` is the same major.minor as `local` but a newer version.

Build metadata is ignored. A prerelease is compared as a prerelease, not stripped.
"""
function juliaup_parent_behind_channel(
        local_version::VersionNumber,
        remote_version::VersionNumber,
    )::Bool
    local_version = _julia_version_without_build(local_version)
    remote_version = _julia_version_without_build(remote_version)
    julia_version_mismatch_kind(local_version, remote_version) == :minor && return false
    return remote_version > local_version
end
