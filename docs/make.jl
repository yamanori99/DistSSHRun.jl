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

if get(ENV, "GITHUB_EVENT_NAME", "") != "pull_request"
    deploydocs(;
        repo = "github.com/yamanori99/DistSSHRun.jl.git",
        devbranch = "main",
        versions = ["stable" => "v^", "v#.#", "dev" => "dev"],
    )
end
