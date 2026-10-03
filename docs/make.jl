using Documenter
using DistSSHRun
using Downloads

DocMeta.setdocmeta!(DistSSHRun, :DocTestSetup, :(using DistSSHRun); recursive = true)

"""Nanosoldier SVG with square corners (`rx=0`), for README / docs."""
function _refresh_pkgeval_badge!()
    dest = joinpath(@__DIR__, "src", "assets", "pkgeval.svg")
    url = "https://juliaci.github.io/NanosoldierReports/pkgeval_badges/D/DistSSHRun.svg"
    try
        svg = String(take!(Downloads.download(url, IOBuffer(); timeout = 15)))
        occursin("PkgEval", svg) || return
        svg = replace(svg, r"rx=\"\d+\"" => "rx=\"0\"")
        svg = replace(svg, r"<linearGradient[\s\S]*?</linearGradient>" => "")
        svg = replace(svg, r"<rect[^>]*fill=\"url\(#s\)\"[^>]*/>" => "")
        write(dest, svg)
    catch e
        @warn "PkgEval badge not refreshed" exception = e
    end
    return nothing
end

_refresh_pkgeval_badge!()

makedocs(;
    modules = [DistSSHRun],
    authors = "Takanori Yamamoto, Honoka Ampuku, and contributors",
    sitename = "DistSSHRun.jl",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://yamanori99.github.io/DistSSHRun.jl",
        size_threshold_ignore = ["api.md"],
        edit_link = "main",
        assets = ["assets/custom.css"],
    ),
    pages = [
        "Introduction" => "index.md",
        "API" => "api.md",
    ],
    checkdocs = :none,
    warnonly = [:missing_docs, :docs_block, :cross_references],
)

deploydocs(;
    repo = "github.com/yamanori99/DistSSHRun.jl.git",
    devbranch = "main",
    push_preview = true,
    versions = ["stable" => "v^", "v#.#", "dev" => "dev"],
)
