using Test
using DistSSHRun

const _REPO_ROOT = abspath(joinpath(@__DIR__, "..", "..", "..", ".."))
const _LIB_SHIP_ENTRY = joinpath(_REPO_ROOT, "lib", "DistSSHShip", "src", "DistSSHShip.jl")
const _RUN_SHIP_MODULE = joinpath(_REPO_ROOT, "src", "DistSSHRun", "ship_module.jl")

function _public_names_from_source(path::AbstractString)::Vector{Symbol}
    names = Symbol[]
    for line in eachline(path)
        m = match(r"^\s*public\s+(\w+)\s*$", line)
        m === nothing && continue
        push!(names, Symbol(m.captures[1]))
    end
    sort!(names)
    return names
end

# Extend this list in later PRs when more engine names retire.
const _RETIRED_ENGINE_PATTERNS = [
    raw"\btransfer_tree\b",
    raw"\bTransferResult\b",
    raw"\bTransferHostResult\b",
    raw"\bshipped_record\b",
    raw"shipped\.toml",
    raw"\bsend_paths\b",
    raw"DistSSHShip\.snapshot\b",
    raw"DistSSHShip\.ShipSnapshot\b",
    raw"\bShipSnapshot\b",
    raw"\bpack_ship_tar\b",
    raw"\bsnapshot_directory\b",
    raw"\bsnapshot_tar\b",
    raw"\bship_project_to_hosts!\b",
    raw"\bShipHostResult\b",
    raw"\btree_matches_head\b",
    raw"\brecord\s*=\s*(?:true|false)",
    raw"\bship_record_logical_path\b",
    raw"\bbuild_ship_record\b",
    raw"\bwrite_ship_record\b",
    raw"\bread_ship_record\b",
    raw"\bread_ship_record_status\b",
    raw"\bship_record_status\b",
    raw"\bverify_ship_record\b",
    raw"\bship_pack\b",
    raw"\brsync_send_list\b",
    raw"\b_instantiate_after_rsync!\b",
]

const _STALE_SCAN_ROOTS = [
    joinpath(_REPO_ROOT, "src"),
    joinpath(_REPO_ROOT, "docs", "src"),
]
for lib in readdir(joinpath(_REPO_ROOT, "lib"))
    src = joinpath(_REPO_ROOT, "lib", lib, "src")
    isdir(src) || continue
    push!(_STALE_SCAN_ROOTS, src)
end

function _stale_engine_vocabulary_hits()::Vector{String}
    hits = String[]
    for root in _STALE_SCAN_ROOTS
        for (dir, _, files) in walkdir(root)
            for file in files
                endswith(file, ".jl") || endswith(file, ".md") || continue
                path = joinpath(dir, file)
                rel = relpath(path, _REPO_ROOT)
                text = read(path, String)
                for pat in _RETIRED_ENGINE_PATTERNS
                    occursin(Regex(pat), text) || continue
                    push!(hits, "$(rel): matches $(pat)")
                end
            end
        end
    end
    return sort(unique(hits))
end

@testset "DistSSHShip public list parity" begin
    lib_names = _public_names_from_source(_LIB_SHIP_ENTRY)
    run_names = _public_names_from_source(_RUN_SHIP_MODULE)
    @test lib_names == run_names
    for name in lib_names
        @test Base.ispublic(DistSSHRun.DistSSHShip, name)
    end
end

@testset "DistSSHShip stale engine vocabulary" begin
    hits = _stale_engine_vocabulary_hits()
    isempty(hits) || error(join(hits, "\n"))
    @test isempty(hits)
end
