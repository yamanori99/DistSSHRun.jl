/-
Audit: `#print axioms` for every proved theorem in the formal model.
The shell wrapper fails if output contains `sorryAxiom` or forbidden names.
-/
import DistSSHBaseFormal.ShellStatus

open DistSSHBaseFormal ShellStatus

#print axioms signaled_branch
#print axioms plain_exit_branch
#print axioms sigint
#print axioms sigpipe
#print axioms sigkill
#print axioms sigterm
#print axioms exit0
#print axioms exit3
#print axioms exit127
#print axioms exit255
#print axioms signaled_ge_129