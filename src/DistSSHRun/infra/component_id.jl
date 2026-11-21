# Precompile-time component fingerprint.

include("component_src_files.jl")

const _RUN_PKG_SRC_ROOT = joinpath(@__DIR__, "..", "..")

const _COMPONENT_SRC_DIGEST = DistSSHBase.src_component_digest(_RUN_PKG_SRC_ROOT, _RUN_SRC_FILES)

const _COMPONENT_PKG_VERSION = begin
    path = joinpath(@__DIR__, "..", "..", "..", "Project.toml")
    if isfile(path)
        string(get(TOML.parsefile(path), "version", "0.0.0"))
    else
        "0.0.0"
    end
end

const COMPONENT_ID = (
    name = "DistSSHRun",
    uuid = Base.UUID("b568025c-2759-4ef1-8b14-17d00e2cd000"),
    version = _COMPONENT_PKG_VERSION,
    digest = _COMPONENT_SRC_DIGEST,
)
