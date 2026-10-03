# Logo & social-preview assets

The mark is original geometry (no Julia dots). MIT, same as the package.

There is no SMIL / GIF bake. The source is `logo/draw.jl` with a **pinned**
Luxor env (`logo/Project.toml` + `logo/Manifest.toml`). Do not `Pkg.add`
Luxor into the package or docs project.

```text
assets/
  custom.css
  README.md
  .raster-stamp-png     after local `--png` (CI freshness)
  favicon.svg / favicon-dark.svg / favicon.ico   tab icon (plum Q; light + dark)
  logo.svg              Documenter light (copy of logo/logo-static.svg)
  logo-dark.svg         Documenter dark (copy of logo/logo-dark-static.svg)
  logo/
    Project.toml        Luxor pin
    Manifest.toml
    draw.jl             source (logo + social SVG)
    logo-static.svg     README light (`<picture>` source)
    logo-dark-static.svg
    logo-static.png     local `--png`; README / JuliaHub fallback
    logo-dark-static.png
  social/
    social-preview-static.svg
    social-preview-static.png   GitHub OG 1280×640 (`--png`)
```

Documenter only discovers `logo.svg` / `logo-dark.svg` at this directory’s
top level. Do not edit those copies by hand.

GitHub README / README.ja use `<picture>` plus `prefers-color-scheme`
for the footer logos. Dark / light `source` are the transparent SVGs.
The fallback `img` is `logo-static.png` (paper background). JuliaHub
strips or ignores `<picture>` / `prefers-color-scheme` (a transparent
light SVG vanishes on a dark page). Absolute
`raw.githubusercontent.com/…/main/docs/src/assets/…` so the files load.

Upload `social/social-preview-static.png` under GitHub → Settings → Social
preview.

```bash
julia --project=docs/src/assets/logo -e 'using Pkg; Pkg.instantiate()'
julia --project=docs/src/assets/logo docs/src/assets/logo/draw.jl
julia --project=docs/src/assets/logo docs/src/assets/logo/draw.jl --png   # rasters
```

CI (`.github/workflows/assets-draw.yml`) re-runs the SVG draw when this tree
changes and fails if SVG outputs drift, or if PNG/ICO look older than their
sources in git history (commit time of the raster, or `.raster-stamp-png`
after a complete `--png`). Draw `--png` locally before committing rasters
(CI does not render them).

Needs [Luxor](https://github.com/JuliaGraphics/Luxor.jl) **4.5** via the pin
above, not a global `] add`.
