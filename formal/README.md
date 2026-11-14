# Formal verification (Lean 4)

This directory follows the workflow of
[**julia-in-lean**](https://github.com/MilesCranmer/julia-in-lean): a
hand-written Lean model mirrors Julia source line by line; docstring promises
become registered `Prop`s with `proven` or `refuted` status; differential
testing links the model to `DistSSHBase`; and `scripts/audit.sh` plus
`Audit.lean` enforce proof hygiene (no `sorry`, axiom allowlist, theorem types).

## What is modeled

- `DistSSHBase._shell_status` in `lib/DistSSHBase/src/ssh/shell_status.jl`
  (lines 24–28), in `DistSSHLean/DistSSHBase/ssh/ShellStatus.lean`.
- The public `shell_status` docstring examples and branch laws are registry
  entries (see `registry.tsv`).

`shell_status(proc::Process)` (non-exited `ArgumentError`) is not modeled yet.

## What “proven” means

A **proven** entry is a theorem about the **Lean model**. Faithfulness to Julia
is established by **differential testing** (`formal/diff/shell_status.jl`), not
by a verified Julia semantics. If the model and Julia disagree, **fix the
model** (julia-in-lean rule).

## Refutations

Per julia-in-lean: a **refuted** entry proves `¬ prop` in Lean and must have a
pure Julia script `repro/<id>.jl` that prints `REPRODUCED <id>` as its **last**
line on real Julia. A Lean counterexample without that reproducer is treated as
a model bug, not a DistSSHBase bug. See `repro/README.md`.

## Local checks

From the repository root (Lean toolchain via `formal/lean-toolchain`, no Mathlib):

```sh
cd formal
lake build
bash scripts/audit.sh          # ends with AUDIT OK; writes .lake/audit.out
bash scripts/run-repros.sh     # no-op when there are no REFUTED lines
lake env lean Report.lean > registry.tsv
```

Differential test (same command as CI):

```sh
julia --project=lib/DistSSHBase formal/diff/shell_status.jl
```

## Layout

| Path | Role |
|------|------|
| `DistSSHLean/` | Lean library (source-mirrored model + registry entries) |
| `Audit.lean`, `Report.lean` | Registry audit and TSV export (julia-in-lean pattern) |
| `registry.tsv` | Exported property list |
| `scripts/audit.sh`, `scripts/run-repros.sh` | Build + audit + reproducers |
| `diff/shell_status.jl` | 10k-case differential test |
| `repro/` | One `repro/<id>.jl` per refuted entry |

## Deviations from julia-in-lean

| Topic | julia-in-lean | Here | Why |
|------|----------------|------|-----|
| Package scope | Whole Base / packages | Single function `_shell_status` | DistSSHRun pilot scope |
| `Except` / `Jl` monad | Exceptions as values | Plain `Int` (no throw path) | Only the integer kernel is modeled |
| Coverage scripts | `check-coverage.jl`, method inventories | Registry `COVER-FN` lines only | One Julia file / two functions |
| `QUESTIONS.md` / `bugs/*.yaml` | Maintainer rulings and bug YAML | Not yet | No refuted bugs filed |
| Differential harness | Many area-specific scripts | One batch exe + `diff/shell_status.jl` | Small input type |

Changing the Julia function requires updating the Lean model, registry entries,
and differential ranges if needed.