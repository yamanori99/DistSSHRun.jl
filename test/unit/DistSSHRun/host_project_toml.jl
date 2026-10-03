using Test
using TOML

@testset "host Project.toml" begin
    kit_root = _kit_root()
    kit_toml = joinpath(kit_root, "Project.toml")
    @test isfile(kit_toml)
    kit = TOML.parsefile(kit_toml)
    kit_deps = Dict{String, String}()
    for (k, v) in kit["deps"]
        kit_deps[String(k)] = String(v)
    end
    parent = dirname(kit_root)
    parent_proj = joinpath(parent, "Project.toml")
    nested_kit = joinpath(parent, "DistSSHRun", "Project.toml")
    # Monorepo: `.../App/DistSSHRun/test` → kit at `App/DistSSHRun`, host `App/Project.toml`.
    # Standalone kit repo: parent has no nested `DistSSHRun/Project.toml`; only assert kit deps exist.
    skip_merge_check = ["Distributed"]
    if isfile(parent_proj) && isfile(nested_kit) && abspath(kit_root) == abspath(joinpath(parent, "DistSSHRun"))
        root_deps = Dict{String, String}()
        for (k, v) in TOML.parsefile(parent_proj)["deps"]
            root_deps[String(k)] = String(v)
        end
        for (n, uuid) in kit_deps
            n in skip_merge_check && continue
            @test haskey(root_deps, n)
            @test root_deps[n] == uuid
        end
    else
        @test haskey(kit_deps, "Distributed")
        @test haskey(kit_deps, "Pkg")
        @test haskey(kit_deps, "Dates")
        @test haskey(kit_deps, "TOML")
    end
    apps = get(kit, "apps", nothing)
    @test apps isa AbstractDict
    @test haskey(apps, "distsshrun")
    @test !haskey(apps, "DistSSHRun")
    @test !haskey(apps, "dsk")
    flags = get(apps["distsshrun"], "julia_flags", nothing)
    @test flags isa AbstractVector
    @test "--startup-file=no" in String.(flags)
end
