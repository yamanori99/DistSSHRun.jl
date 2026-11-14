import DistSSHBaseFormal.ShellStatus

open DistSSHBaseFormal

/--
Batch driver for differential testing: read lines `exitcode termsignal` from stdin,
print one `shellStatus` result per line.
-/
def main : IO Unit := do
  let lines ← (← IO.getStdin).readToEnd
  for line in lines.splitOn "\n" do
    if line.isEmpty then continue
    let parts := (line.splitOn " ").filter (· ≠ "")
    match parts with
    | [ec, ts] =>
      let exitcode := ec.toInt!
      let termsignal := ts.toInt!
      IO.println (shellStatus exitcode termsignal)
    | _ =>
      throw <| IO.userError s!"expected two integers, got {line}"