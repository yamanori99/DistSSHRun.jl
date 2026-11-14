/-!
Formal model of `DistSSHBase._shell_status` from
`lib/DistSSHBase/src/ssh/shell_status.jl` (lines 24–28).

A negative `termsignal` is not modeled as a separate exception; it falls through to
`exitcode`, matching the Julia branch order (`termsignal > 0` only).
-/

namespace DistSSHBaseFormal

/-- Shell status from exit code and termination signal (`128 + signal` when signaled). -/
def shellStatus (exitcode termsignal : Int) : Int :=
  if termsignal > 0 then
    128 + termsignal
  else
    exitcode

namespace ShellStatus

theorem signaled_branch (exitcode termsignal : Int) (h : termsignal > 0) :
    shellStatus exitcode termsignal = 128 + termsignal := by
  simp [shellStatus, h]

theorem plain_exit_branch (exitcode termsignal : Int) (h : ¬ termsignal > 0) :
    shellStatus exitcode termsignal = exitcode := by
  simp [shellStatus, h]

theorem sigint (exitcode : Int) : shellStatus exitcode 2 = 130 := by
  simp [shellStatus]

theorem sigpipe (exitcode : Int) : shellStatus exitcode 13 = 141 := by
  simp [shellStatus]

theorem sigkill (exitcode : Int) : shellStatus exitcode 9 = 137 := by
  simp [shellStatus]

theorem sigterm (exitcode : Int) : shellStatus exitcode 15 = 143 := by
  simp [shellStatus]

theorem exit0 (termsignal : Int) (h : ¬ termsignal > 0) : shellStatus 0 termsignal = 0 := by
  simp [plain_exit_branch, h]

theorem exit3 (termsignal : Int) (h : ¬ termsignal > 0) : shellStatus 3 termsignal = 3 := by
  simp [plain_exit_branch, h]

theorem exit127 (termsignal : Int) (h : ¬ termsignal > 0) : shellStatus 127 termsignal = 127 := by
  simp [plain_exit_branch, h]

theorem exit255 (termsignal : Int) (h : ¬ termsignal > 0) : shellStatus 255 termsignal = 255 := by
  simp [plain_exit_branch, h]

theorem signaled_ge_129 (exitcode termsignal : Int) (h : termsignal > 0) :
    shellStatus exitcode termsignal ≥ 129 := by
  have : shellStatus exitcode termsignal = 128 + termsignal :=
    signaled_branch exitcode termsignal h
  rw [this]
  omega

end ShellStatus

end DistSSHBaseFormal