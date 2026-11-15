# Load a package for tool/runtime probes: `require`, then reject same-name UUID collisions.

"""
    tool_require(pkg::Base.PkgId) -> Module

Family-internal helper (not public API). Load `pkg` when it is not already
loaded. If another package with the same `name` and a different `uuid` is already
loaded, throw `ErrorException`.
"""
function tool_require(pkg::Base.PkgId)
    for (loaded, _) in Base.loaded_modules
        loaded.name == pkg.name && loaded.uuid != pkg.uuid && throw(
            ErrorException(
                "tool_require: package name collision for $(pkg.name): " *
                    "loaded $(loaded.uuid), wanted $(pkg.uuid)",
            ),
        )
    end
    haskey(Base.loaded_modules, pkg) && return Base.loaded_modules[pkg]
    return Base.require(pkg)
end
