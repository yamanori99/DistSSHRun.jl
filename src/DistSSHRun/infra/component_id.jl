# Precompile-time component fingerprint (schema 1).

include("component_src_files.jl")

const _RUN_PKG_SRC_ROOT = joinpath(@__DIR__, "..", "..")

const _COMPONENT_SRC_DIGEST = DistSSHBase.src_component_digest(_RUN_PKG_SRC_ROOT, _RUN_SRC_FILES)

const COMPONENT_ID = (
    schema = 1,
    name = "DistSSHRun",
    uuid = Base.UUID("b568025c-2759-4ef1-8b14-17d00e2cd000"),
    version = "0.2.0-DEV",
    digest = _COMPONENT_SRC_DIGEST,
)
