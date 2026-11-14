# Bug write-ups

Each confirmed bug (after a refuted registry entry and a passing `repro/<id>.jl`)
gets a YAML file `bugs/<id>.yaml` validated by `scripts/check-bugs.sh`.

Schema and workflow match
[julia-in-lean](https://github.com/MilesCranmer/julia-in-lean) (`julia-base/bugs/`,
`scripts/check_bugs.py`). Required fields include `priority` (P0–P3), `kind`,
`files`, `functions`, `output.release` / `output.nightly`, `reproduced.*`,
`duplicates`, and `lean.property` / `lean.theorem`.

**Filing upstream is never automated.** A human approves each issue before it is
posted to JuliaLang/julia, DistSSHRun, or any other tracker.

There are no bug write-ups yet.