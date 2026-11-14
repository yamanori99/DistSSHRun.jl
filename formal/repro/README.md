# Refutation reproducers

Following [julia-in-lean](https://github.com/MilesCranmer/julia-in-lean): a **refuted**
registry entry needs a pure Julia script `repro/<id>.jl` that prints
`REPRODUCED <id>` as its **last** line when the behaviour appears on real Julia.
A Lean counterexample alone is a model bug; the reproducer is what ties a
refutation to the package.

There are no refuted entries for `_shell_status` yet. If you add one, also add
`repro/<id>.jl` and run `bash scripts/run-repros.sh` after `scripts/audit.sh`.