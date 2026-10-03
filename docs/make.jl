using Documenter
using DistSSHRun
using Base64
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

const FAVICON_PNG_B64 = base64encode(read(joinpath(@__DIR__, "src", "assets", "favicon.png")))
const FAVICON_DARK_PNG_B64 = base64encode(read(joinpath(@__DIR__, "src", "assets", "favicon-dark.png")))

makedocs(;
    modules = [DistSSHRun],
    authors = "Takanori Yamamoto, Honoka Ampuku, and contributors",
    sitename = "DistSSHRun.jl",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://yamanori99.github.io/DistSSHRun.jl",
        size_threshold_ignore = ["api.md"],
        edit_link = "main",
        assets = [
            "assets/custom.css",
            RawHTMLHeadContent(
                """<link id="docs-favicon" rel="icon" type="image/png" sizes="32x32" href="data:image/png;base64,$(FAVICON_PNG_B64)" data-light="data:image/png;base64,$(FAVICON_PNG_B64)" data-dark="data:image/png;base64,$(FAVICON_DARK_PNG_B64)"/>""",
            ),
            "assets/favicon-theme.js",
        ],
    ),
    pages = [
        "Introduction" => "index.md",
        "API" => "api.md",
    ],
    checkdocs = :none,
    warnonly = [:missing_docs, :docs_block, :cross_references],
)

function rewrite_favicon_types!(build)
    rx_svg = r"""<link href="([^"]*favicon\.svg)" rel="icon" type="image/x-icon" type="image/svg\+xml"/>"""
    rx_png = r"""<link href="([^"]*favicon\.png)" rel="icon" type="image/x-icon" type="image/png" sizes="32x32"/>"""
    n = 0
    for (root, _, files) in walkdir(build)
        for f in files
            endswith(f, ".html") || continue
            path = joinpath(root, f)
            html = read(path, String)
            html2 = replace(
                html,
                rx_svg => s"""<link href="\1" rel="icon" type="image/svg+xml"/>""",
            )
            html2 = replace(
                html2,
                rx_png => s"""<link href="\1" rel="icon" type="image/png" sizes="32x32"/>""",
            )
            if html2 != html
                write(path, html2)
                n += 1
            end
        end
    end
    return println("rewrote favicon type on $n HTML pages")
end

rewrite_favicon_types!(joinpath(@__DIR__, "build"))

deploydocs(;
    repo = "github.com/yamanori99/DistSSHRun.jl.git",
    devbranch = "main",
    push_preview = true,
    versions = ["stable" => "v^", "v#.#", "dev" => "dev"],
)
