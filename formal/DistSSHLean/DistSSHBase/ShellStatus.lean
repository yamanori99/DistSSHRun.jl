import DistSSHLean.Registry.Types

/-!
Source-mirrored model of `lib/DistSSHBase/src/ssh/shell_status.jl`.

Only `_shell_status(exitcode, termsignal)` is modelled (lines 24–28). A negative
`termsignal` is not special-cased in Julia; the model matches the branch order.
-/

namespace DistSSHLean.DistSSHBase.ShellStatus

/-- `lib/DistSSHBase/src/ssh/shell_status.jl:24-28`: shell `128 + signal` rule. -/
def shellStatus (exitcode termsignal : Int) : Int :=
  if termsignal > 0 then
    128 + termsignal
  else
    exitcode

def signaledBranchProp : Prop :=
  ∀ (exitcode termsignal : Int), termsignal > 0 →
    shellStatus exitcode termsignal = 128 + termsignal

theorem signaledBranch_holds : signaledBranchProp := by
  intro exitcode termsignal h
  simp [shellStatus, h]

def plainExitProp : Prop :=
  ∀ (exitcode termsignal : Int), ¬ termsignal > 0 →
    shellStatus exitcode termsignal = exitcode

theorem plainExit_holds : plainExitProp := by
  intro exitcode termsignal h
  simp [shellStatus, h]

def sigintProp : Prop :=
  ∀ (exitcode : Int), shellStatus exitcode 2 = 130

theorem sigint_holds : sigintProp := by
  intro exitcode
  simp [shellStatus]

def sigpipeProp : Prop :=
  ∀ (exitcode : Int), shellStatus exitcode 13 = 141

theorem sigpipe_holds : sigpipeProp := by
  intro exitcode
  simp [shellStatus]

def sigkillProp : Prop :=
  ∀ (exitcode : Int), shellStatus exitcode 9 = 137

theorem sigkill_holds : sigkillProp := by
  intro exitcode
  simp [shellStatus]

def sigtermProp : Prop :=
  ∀ (exitcode : Int), shellStatus exitcode 15 = 143

theorem sigterm_holds : sigtermProp := by
  intro exitcode
  simp [shellStatus]

def exit0Prop : Prop :=
  ∀ (termsignal : Int), ¬ termsignal > 0 → shellStatus 0 termsignal = 0

theorem exit0_holds : exit0Prop := by
  intro termsignal h
  simpa using plainExit_holds 0 termsignal h

def exit3Prop : Prop :=
  ∀ (termsignal : Int), ¬ termsignal > 0 → shellStatus 3 termsignal = 3

theorem exit3_holds : exit3Prop := by
  intro termsignal h
  simpa using plainExit_holds 3 termsignal h

def exit127Prop : Prop :=
  ∀ (termsignal : Int), ¬ termsignal > 0 → shellStatus 127 termsignal = 127

theorem exit127_holds : exit127Prop := by
  intro termsignal h
  simpa using plainExit_holds 127 termsignal h

def exit255Prop : Prop :=
  ∀ (termsignal : Int), ¬ termsignal > 0 → shellStatus 255 termsignal = 255

theorem exit255_holds : exit255Prop := by
  intro termsignal h
  simpa using plainExit_holds 255 termsignal h

def signaledGe129Prop : Prop :=
  ∀ (exitcode termsignal : Int), termsignal > 0 →
    shellStatus exitcode termsignal ≥ 129

theorem signaledGe129_holds : signaledGe129Prop := by
  intro exitcode termsignal h
  have heq : shellStatus exitcode termsignal = 128 + termsignal :=
    signaledBranch_holds exitcode termsignal h
  rw [heq]
  omega

def shellStatusSourceFile : String := "lib/DistSSHBase/src/ssh/shell_status.jl"

def entries : List DistSSHLean.Registry.Entry := [
  { id := "shell-status-signaled-branch"
    juliaFile := shellStatusSourceFile
    juliaFns := ["_shell_status", "shell_status"]
    statement := "When termsignal > 0, status is 128 + termsignal (shell rule)."
    preconditions := "Any Int exitcode and termsignal; only the termsignal > 0 branch."
    status := .proven
    prop := ``signaledBranchProp
    thm := some ``signaledBranch_holds },
  { id := "shell-status-plain-exit"
    juliaFile := shellStatusSourceFile
    juliaFns := ["_shell_status"]
    statement := "When termsignal is not positive, status is exitcode unchanged."
    preconditions := "¬ (termsignal > 0), including termsignal <= 0."
    status := .proven
    prop := ``plainExitProp
    thm := some ``plainExit_holds },
  { id := "shell-status-sigint"
    juliaFile := shellStatusSourceFile
    juliaFns := ["_shell_status", "shell_status"]
    statement := "SIGINT (termsignal 2) yields status 130 for any exitcode."
    preconditions := "Docstring example (SIGINT 130)."
    status := .proven
    prop := ``sigintProp
    thm := some ``sigint_holds },
  { id := "shell-status-sigpipe"
    juliaFile := shellStatusSourceFile
    juliaFns := ["_shell_status", "shell_status"]
    statement := "SIGPIPE (termsignal 13) yields status 141."
    preconditions := "Docstring example."
    status := .proven
    prop := ``sigpipeProp
    thm := some ``sigpipe_holds },
  { id := "shell-status-sigkill"
    juliaFile := shellStatusSourceFile
    juliaFns := ["_shell_status", "shell_status"]
    statement := "SIGKILL (termsignal 9) yields status 137."
    preconditions := "Docstring example."
    status := .proven
    prop := ``sigkillProp
    thm := some ``sigkill_holds },
  { id := "shell-status-sigterm"
    juliaFile := shellStatusSourceFile
    juliaFns := ["_shell_status", "shell_status"]
    statement := "SIGTERM (termsignal 15) yields status 143."
    preconditions := "Docstring example."
    status := .proven
    prop := ``sigtermProp
    thm := some ``sigterm_holds },
  { id := "shell-status-exit-0"
    juliaFile := shellStatusSourceFile
    juliaFns := ["_shell_status"]
    statement := "Plain exit 0 is returned when not signaled."
    preconditions := "Docstring example; ¬ (termsignal > 0)."
    status := .proven
    prop := ``exit0Prop
    thm := some ``exit0_holds },
  { id := "shell-status-exit-3"
    juliaFile := shellStatusSourceFile
    juliaFns := ["_shell_status"]
    statement := "Plain exit 3 is returned when not signaled."
    preconditions := "Docstring example; ¬ (termsignal > 0)."
    status := .proven
    prop := ``exit3Prop
    thm := some ``exit3_holds },
  { id := "shell-status-exit-127"
    juliaFile := shellStatusSourceFile
    juliaFns := ["_shell_status"]
    statement := "Plain exit 127 is returned when not signaled."
    preconditions := "Docstring example; ¬ (termsignal > 0)."
    status := .proven
    prop := ``exit127Prop
    thm := some ``exit127_holds },
  { id := "shell-status-exit-255"
    juliaFile := shellStatusSourceFile
    juliaFns := ["_shell_status"]
    statement := "Plain exit 255 is returned when not signaled."
    preconditions := "Docstring example; ¬ (termsignal > 0)."
    status := .proven
    prop := ``exit255Prop
    thm := some ``exit255_holds },
  { id := "shell-status-signaled-ge-129"
    juliaFile := shellStatusSourceFile
    juliaFns := ["_shell_status"]
    statement := "Any signaled status is at least 129."
    preconditions := "termsignal > 0."
    status := .proven
    prop := ``signaledGe129Prop
    thm := some ``signaledGe129_holds },
]

end DistSSHLean.DistSSHBase.ShellStatus