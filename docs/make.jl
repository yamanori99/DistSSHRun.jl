using Documenter
using DistSSHRun

DocMeta.setdocmeta!(DistSSHRun, :DocTestSetup, :(using DistSSHRun); recursive = true)

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
