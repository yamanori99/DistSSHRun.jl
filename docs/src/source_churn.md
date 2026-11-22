# Source churn

Developer view of line churn in non-blank `*.jl` files under package `src/`
trees (`src/` and `lib/*/src/`). Metrics use git history on `main` (rename-aware,
JST 7d/30d windows) and refresh on the compile-bench schedule.

## Where to read the latest report

The live tables and charts are published on the
[`bench-data`](https://github.com/yamanori99/DistSSHRun.jl/tree/bench-data/churn)
branch only (not in the repository README):

- [Churn report (`report.md`)](https://github.com/yamanori99/DistSSHRun.jl/blob/bench-data/churn/report.md)
- [Summary CSV](https://github.com/yamanori99/DistSSHRun.jl/blob/bench-data/churn/summary.csv)
- PNG previews and interactive HTML under `churn/charts/` (linked from `report.md`)

## Tests and local render

```bash
julia --startup-file=no --project=. bench/compile/test/churn.jl
julia --startup-file=no --project=bench/compile bench/compile/churn_render.jl \
    --out-dir /tmp/churn-out
```

Optional: `--append-docs PATH --docs-chart-base URL` splices generated tables into a
markdown file (for ad-hoc previews only; CI does not commit docs sources).
