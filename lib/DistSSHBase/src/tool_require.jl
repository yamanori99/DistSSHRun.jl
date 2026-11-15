# Family-internal package load helper (collision + DistSSH uuid guards).

const _DISTSSH_FAMILY_UUIDS = (
    Base.UUID("f0a69307-14e5-4272-8c28-20680d05bac8"), # DistSSHBase
    Base.UUID("b568025c-2759-4ef1-8b14-17d00e2cd000"), # DistSSHRun
    Base.UUID("24254401-70d8-4a51-8ea4-cfab19f5bc73"), # DistSSHQueue
    Base.UUID("ceec0504-c968-4be5-b215-667cae0e8f81"), # DistSSHKit
)

function _distssh_family_uuid(uuid::Base.UUID)::Bool
    for u in _DISTSSH_FAMILY_UUIDS
        u == uuid && return true
    end
    return false
end

"""
    tool_require(pkg::Base.PkgId) -> Module

Family-internal helper (not public API). Load `pkg` when it is not already
loaded. Rejects same-name UUID collisions and refuses DistSSH family package
uuids at this boundary (use loaded-module inspection elsewhere).
"""
function tool_require(pkg::Base.PkgId)
    uuid = pkg.uuid
    uuid === nothing &&
        throw(ErrorException("tool_require: package $(pkg.name) has no uuid"))
    _distssh_family_uuid(uuid) && throw(
        ErrorException(
            "tool_require: refusing DistSSH family package $(pkg.name) ($(pkg.uuid))",
        ),
    )
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
