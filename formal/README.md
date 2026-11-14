# Formal verification (Lean 4)

This tree holds a minimal [Lean 4](https://lean-lang.org/) model of selected
`DistSSHBase` behavior. It is not a full verification of the Julia package—only
the functions we choose to mirror here.

## What is modeled

- `DistSSHBase._shell_status` from `lib/DistSSHBase/src/ssh/shell_status.jl`
  (lines 24–28), as `DistSSHBaseFormal.shellStatus` in
  `formal/DistSSHBase/DistSSHBaseFormal/ShellStatus.lean`.

The Lean definition follows the same branch order: `termsignal > 0` implies
`128 + termsignal`, otherwise `exitcode`. Negative `termsignal` values are not
special-cased in Julia; the model matches that.

Docstring examples (0, 3, 127, 255 and SIGINT/SIGPIPE/SIGKILL/SIGTERM) and
branch properties are stated as theorems in that module.

## What “proven” means here

A theorem is a statement about the **Lean model**, checked by the Lean kernel.
Linkage to Julia is **differential testing**: the same inputs are run through
`DistSSHBase._shell_status` (or the inlined reference in the diff script) and
through the compiled Lean batch executable; any mismatch fails the test.

Changing the Julia function without updating the Lean model (and theorems or diff
range, if needed) should break CI.

## Local commands

Install [elan](https://github.com/leanprover/elan), then from the repository root:

```bash
cd formal/DistSSHBase && lake build
../audit/run.sh
```

Differential test (build first):

```bash
HOME=/tmp/lean-home JULIA_DEPOT_PATH=/tmp/lean-julia-depot \
  julia --project="$PWD" formal/diff/shell_status.jl
```

Or activate the repo root `Project.toml` if `DistSSHBase` is already available.

## Layout

| Path | Role |
|------|------|
| `DistSSHBase/` | Lake package (`lean-toolchain`, `lakefile.lean`, library + `shell_status_batch` exe) |
| `diff/shell_status.jl` | 10k-case deterministic differential test |
| `audit/run.sh` | `sorry` / `native_decide` grep + `#print axioms` check |

CI runs the same steps in `.github/workflows/formal.yml` when `formal/` or
`lib/DistSSHBase/src/ssh/shell_status.jl` changes.