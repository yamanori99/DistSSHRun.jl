# Formal verification (Lean 4)

This directory follows
[**julia-in-lean**](https://github.com/MilesCranmer/julia-in-lean): a hand-written
Lean model mirrors Julia source line by line; docstring promises become registered
`Prop`s (`proven` / `refuted`); differential testing links the model to
`DistSSHBase`; `Audit.lean` and `scripts/audit.sh` enforce proof hygiene;
refutations require Julia reproducers; `QUESTIONS.md` holds ambiguous semantics;
`bugs/*.yaml` records confirmed bugs (human-approved filing only).

## What is modeled

- `lib/DistSSHBase/src/ssh/shell_status.jl` in
  `DistSSHLean/DistSSHBase/ShellStatus.lean`
- `_shell_status(exitcode, termsignal)` and `shell_status(proc)` including
  `ArgumentError` when the child has not exited (`Jl` / `Except JlError`, as in
  julia-in-lean).

## What “proven” means

A **proven** entry is a theorem about the **Lean model**. Faithfulness to Julia is
**differential testing** (`formal/diff/shell_status.jl`). If model and Julia
disagree, fix the model.

## Refutations

A **refuted** entry proves `¬ prop` and needs `repro/<id>.jl` printing
`REPRODUCED <id>` as its **last** line on real Julia. Without that, the
counterexample is a model bug. See `repro/README.md` and `bugs/README.md`.

Upstream issue filing is **never automated**; a human approves each report.

## Local checks

From the repository root (toolchain in `formal/lean-toolchain`, no Mathlib):

```sh
cd formal
lake build
bash scripts/audit.sh          # AUDIT OK; coverage; bugs schema
bash scripts/run-repros.sh     # when REFUTED lines exist
lake env lean Report.lean > registry.tsv
julia --project=../lib/DistSSHBase diff/shell_status.jl
```

From the repo root the differential test is:

```sh
julia --project=lib/DistSSHBase formal/diff/shell_status.jl
```

## Layout

| Path | Role |
|------|------|
| `DistSSHLean/` | Models, `Registry`, `Runtime` (`Jl`, `JlError`) |
| `Audit.lean`, `Report.lean`, `registry.tsv` | Registry audit and export |
| `scripts/audit.sh`, `check-coverage.jl`, `check-bugs.sh` | julia-in-lean checks |
| `scripts/check-coverage.jl` | Registry coverage vs in-scope file and functions |
| `QUESTIONS.md` | Maintainer rulings on ambiguous behaviour |
| `bugs/` | YAML write-ups for confirmed bugs |
| `diff/shell_status.jl` | Differential test |
| `repro/` | One `repro/<id>.jl` per refuted entry |

Changing Julia `shell_status.jl` requires updating the Lean model, registry, coverage
scope if needed, and the differential harness.