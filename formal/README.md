> [!WARNING]
> **Experimental.** The Lean models and proofs under `formal/` are an experiment.
> They cover only `DistSSHBase._shell_status` and `DistSSHBase.shell_status` in
> `lib/DistSSHBase/src/ssh/shell_status.jl`, are not part of the package's public
> API or release guarantees, and may change or be removed without notice. Passing
> proofs certify properties of the Lean model (checked against Julia via differential
> testing), not DistSSHRun or DistSSHBase as a whole.

## POSIX `posix_quote` (experimental)

**Modeled:** POSIX single-word parsing subset used to read `posix_quote` output:
single-quoted runs, `\\` escapes outside quotes, and IFS whitespace as a word terminator
(`DistSSHLean/DistSSHBase/PosixQuote/`). Double quotes, expansions, and line continuation
are out of scope.

**Proven (Lean model):** `posixQuote_roundtrip_chars`, `posixQuote_roundtrip` (one word, no
trailing non-IFS via `shParseWordChars`), plus NUL vs non-NUL `posixQuote` branches.
`decQb_qb` relates `qb` to `decQb` only; there is no formal link from Julia
`posix_quote` to the model’s `qb`.

**Not proven:** Faithfulness of `posix_quote` / `qb` to Julia — checked by
`scripts/differential_full.jl` against `/bin/dash`, `bash --posix`, `zsh -f`, and
`zsh emulate sh`, and the built `sh_posix_eval` exe (same parser as the proofs).

```sh
cd formal
lake build sh_posix_eval
julia --project=../lib/DistSSHBase scripts/differential_full.jl
```

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
| `scripts/check-proof-escapes.py` | Syntax-aware proof-escape scan (adapted from [julia-in-lean](https://github.com/MilesCranmer/julia-in-lean) `check-proof-escapes.py`, Apache-2.0) |
| `scripts/check-coverage.jl` | Registry coverage vs in-scope file and functions |
| `QUESTIONS.md` | Maintainer rulings on ambiguous behaviour |
| `bugs/` | YAML write-ups for confirmed bugs (`scripts/audit.sh` always needs PyYAML; `pip install pyyaml` on macOS if needed) |
| `diff/shell_status.jl` | Differential test (`shell_status`) |
| `scripts/differential_full.jl` | `posix_quote` vs shells + Lean eval |
| `PosixQuoteEval.lean` | `lake build sh_posix_eval` batch driver |
| `repro/` | One `repro/<id>.jl` per refuted entry |

Changing Julia `shell_status.jl` or `posix_quote` / `ssh.jl` requires updating the Lean
model, registry, coverage scope if needed, and the matching differential harness.