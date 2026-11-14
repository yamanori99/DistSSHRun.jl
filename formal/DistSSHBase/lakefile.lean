import Lake
open Lake DSL

package «DistSSHBaseFormal» where
  leanOptions := #[⟨`autoImplicit, false⟩]

lean_lib «DistSSHBaseFormal» where
  roots := #[`DistSSHBaseFormal]

@[default_target]
lean_exe «shell_status_batch» where
  root := `ShellStatusBatch
  supportInterpreter := false