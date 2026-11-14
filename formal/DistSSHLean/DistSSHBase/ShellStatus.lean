import DistSSHLean.Runtime.Errors
import DistSSHLean.Registry.Types

open DistSSHLean

/-!
Source-mirrored model of `lib/DistSSHBase/src/ssh/shell_status.jl`.
-/

namespace DistSSHLean.DistSSHBase.ShellStatus

/-- Minimal `Base.Process` fields used by `shell_status`. -/
structure Process where
  exited : Bool
  exitcode : Int
  termsignal : Int
  deriving Repr

def shellStatusSourceFile : String := "lib/DistSSHBase/src/ssh/shell_status.jl"

def shellStatusNotExitedMsg : String := "shell_status: process has not exited"

/-- `shell_status.jl:18`: `process_exited(proc)`. -/
def processExited (p : Process) : Bool := p.exited

/-- `shell_status.jl:24-28`. -/
def _shellStatus (exitcode termsignal : Int) : Int :=
  if termsignal > 0 then
    128 + termsignal
  else
    exitcode

/-- `shell_status.jl:17-19` (`process_exited` then `_shell_status`). -/
def shellStatus (p : Process) : Jl Int :=
  if p.exited then
    .ok (_shellStatus p.exitcode p.termsignal)
  else
    .error (.argumentError shellStatusNotExitedMsg)

def signaledBranchProp : Prop :=
  ∀ (exitcode termsignal : Int), termsignal > 0 →
    _shellStatus exitcode termsignal = 128 + termsignal

theorem signaledBranch_holds : signaledBranchProp := by
  intro exitcode termsignal h
  simp [_shellStatus, h]

def plainExitProp : Prop :=
  ∀ (exitcode termsignal : Int), ¬ termsignal > 0 →
    _shellStatus exitcode termsignal = exitcode

theorem plainExit_holds : plainExitProp := by
  intro exitcode termsignal h
  simp [_shellStatus, h]

def signaledGe129Prop : Prop :=
  ∀ (exitcode termsignal : Int), termsignal > 0 →
    _shellStatus exitcode termsignal ≥ 129

theorem signaledGe129_holds : signaledGe129Prop := by
  intro exitcode termsignal h
  have heq : _shellStatus exitcode termsignal = 128 + termsignal :=
    signaledBranch_holds exitcode termsignal h
  rw [heq]
  omega

theorem processExited_eq (p : Process) : processExited p = p.exited := rfl

def shellStatusExitedOkProp : Prop :=
  ∀ (p : Process), p.exited →
    shellStatus p = .ok (_shellStatus p.exitcode p.termsignal)

theorem shellStatusExitedOk_holds : shellStatusExitedOkProp := by
  intro p hp
  simp [shellStatus, hp]

def shellStatusNotExitedErrProp : Prop :=
  ∀ (p : Process), ¬ p.exited →
    shellStatus p = .error (.argumentError shellStatusNotExitedMsg)

theorem shellStatusNotExitedErr_holds : shellStatusNotExitedErrProp := by
  intro p hn
  simp [shellStatus, hn]

def entries : List DistSSHLean.Registry.Entry := [
  { id := "shell-status-signaled-branch"
    juliaFile := shellStatusSourceFile
    juliaFns := ["_shell_status", "shell_status"]
    statement := "When termsignal > 0, status is 128 + termsignal (shell rule)."
    preconditions := "Integer exitcode and termsignal; termsignal > 0 branch."
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
  { id := "shell-status-signaled-ge-129"
    juliaFile := shellStatusSourceFile
    juliaFns := ["_shell_status"]
    statement := "Any signaled status is at least 129."
    preconditions := "termsignal > 0."
    status := .proven
    prop := ``signaledGe129Prop
    thm := some ``signaledGe129_holds },
  { id := "shell-status-proc-exited"
    juliaFile := shellStatusSourceFile
    juliaFns := ["shell_status"]
    statement := "When the child has exited, shell_status returns _shell_status on its codes."
    preconditions := "process_exited(proc)."
    status := .proven
    prop := ``shellStatusExitedOkProp
    thm := some ``shellStatusExitedOk_holds },
  { id := "shell-status-proc-not-exited"
    juliaFile := shellStatusSourceFile
    juliaFns := ["shell_status"]
    statement := "When the child has not exited, shell_status throws ArgumentError with the docstring message."
    preconditions := "¬ process_exited(proc)."
    status := .proven
    prop := ``shellStatusNotExitedErrProp
    thm := some ``shellStatusNotExitedErr_holds },
]

end DistSSHLean.DistSSHBase.ShellStatus