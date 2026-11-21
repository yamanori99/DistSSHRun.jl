using Test

const _DOC_WALK_ROOTS = [
    "README.md",
    "README.ja.md",
    joinpath("docs", "src"),
    "demos",
    joinpath("testenv", "docker-ssh"),
    joinpath("testenv", "apple-container-ssh"),
]

# Instructional leftovers from pre-0.2.0 placement / doctor CLI (issue #486).
const _FORBIDDEN_DOC_RE = [
    Regex("setup check") => "doctor --deploy",
    Regex("parent:[0-9]") => "--head-workers or N*host",
    Regex("child:[a-zA-Z]") => "plain SSH host names",
    Regex("--local-workers") => "--head-workers",
    Regex("--local-slots") => "--head-slots",
    Regex("DISTSSH_LOCAL_WORKERS") => "DISTSSH_HEAD_WORKERS",
    Regex(raw"drive` / `drive") => "drive / go",
]

function _doc_walk_paths(root::AbstractString)::Vector{String}
    out = String[]
    for rel in _DOC_WALK_ROOTS
        path = joinpath(root, rel)
        isdir(path) || (isfile(path) && push!(out, path); continue)
        for (dir, _, files) in walkdir(path)
            for f in files
                endswith(f, ".md") && push!(out, joinpath(dir, f))
                endswith(f, ".jl") && push!(out, joinpath(dir, f))
                f == "compose.yml" && push!(out, joinpath(dir, f))
                f == "with-env.sh" && push!(out, joinpath(dir, f))
            end
        end
    end
    return out
end

function _scan_forbidden_docs(root::AbstractString)
    hits = Tuple{String, Int, String, String}[]
    for path in _doc_walk_paths(root)
        rel = relpath(path, root)
        skip_placement = rel == joinpath("docs", "src", "common_errors.md")
        for (i, line) in enumerate(split(read(path, String), '\n'; keepempty = true))
            for (re, hint) in _FORBIDDEN_DOC_RE
                skip_placement && occursin(re, line) && continue
                occursin(re, line) || continue
                push!(hits, (rel, i, hint, line))
            end
        end
    end
    return hits
end

# Bash / comment lines that must stay parseable (kept in sync with README + docs Commands).
const _DOCUMENTED_PARSE_CASES = [
    (DistSSHRun.parse_go_args, String["SCRIPT.jl"]),
    (DistSSHRun.parse_go_args, String["--head-slots", "2", "SCRIPT.jl"]),
    (DistSSHRun.parse_drive_args, String["--head-workers", "2", "SCRIPT.jl"]),
    (
        DistSSHRun.parse_drive_args,
        String["--head-workers", "2", "--hosts", "4*user@lab:2222,2*lab-b", "script.jl"],
    ),
    (DistSSHRun.parse_doctor_args, String["--deploy", "host1"]),
    (DistSSHRun.parse_up_args, String["status", "child-1", "child-2", "--verbose"]),
]

@testset "docs and demos CLI examples" begin
    @testset "forbidden placement / doctor wording" begin
        hits = _scan_forbidden_docs(_kit_root())
        if !isempty(hits)
            for (file, line, hint, text) in hits
                @warn "legacy CLI wording" file line hint text
            end
        end
        @test hits == []
    end

    @testset "documented argv parses" begin
        for (parser, argv) in _DOCUMENTED_PARSE_CASES
            @test parser(argv) !== nothing
        end
    end
end
