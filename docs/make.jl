using Documenter
using DistSSHRun

DocMeta.setdocmeta!(DistSSHRun, :DocTestSetup, :(using DistSSHRun); recursive = true)

makedocs(;
    modules = [DistSSHRun, DistSSHRun.DistSSHBase, DistSSHRun.DistSSHUp],
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
        "Home" => "index.md",
        "API" => "api.md",
    ],
    checkdocs = :none,
)

# A pull request from this repository deploys previews/PR<n>.
# A local run has no token, so deploydocs records the criteria and skips.
deploydocs(;
    repo = "github.com/yamanori99/DistSSHRun.jl.git",
    devbranch = "main",
    push_preview = true,
    versions = ["stable" => "v^", "v#.#", "dev" => "dev"],
)
