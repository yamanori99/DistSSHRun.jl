# Refutation reproducers

Following [julia-in-lean](https://github.com/MilesCranmer/julia-in-lean): a
**refuted** registry entry needs a pure Julia script `repro/<id>.jl` that prints
`REPRODUCED <id>` as its **last** line when the behaviour appears on real Julia.

`scripts/run-repros.sh` runs every reproducer listed in `.lake/audit.out` after
`scripts/audit.sh`.

There are no refuted entries yet. Confirmed bugs also get `bugs/<id>.yaml`;
**filing upstream is never automated** — a human approves each issue.