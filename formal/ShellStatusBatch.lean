import DistSSHLean.DistSSHBase.ShellStatus

open DistSSHLean
open DistSSHLean.DistSSHBase.ShellStatus

/--
Batch driver for `formal/diff/shell_status.jl`.

Input lines (whitespace-separated):
  `i <exitcode> <termsignal>` — `_shellStatus`
  `p <exited> <exitcode> <termsignal>` — `shellStatus` on `Process` (`exited` is 0 or 1)

Output:
  `OK <int>` on success
  `ERR argumentError <msg>` on modeled `ArgumentError`
-/

def printJlInt (r : Jl Int) : IO Unit :=
  match r with
  | .ok n => IO.println s!"OK {n}"
  | .error (.argumentError msg) => IO.println s!"ERR argumentError {msg}"

def main : IO Unit := do
  let lines ← (← IO.getStdin).readToEnd
  for line in lines.splitOn "\n" do
    if line.isEmpty then continue
    let parts := (line.splitOn " ").filter (· ≠ "")
    match parts with
    | "i" :: [ec, ts] =>
      let exitcode := ec.toInt!
      let termsignal := ts.toInt!
      IO.println s!"OK {_shellStatus exitcode termsignal}"
    | "p" :: [ex, ec, ts] =>
      let exited := ex == "1"
      let p : Process := ⟨exited, ec.toInt!, ts.toInt!⟩
      printJlInt (shellStatus p)
    | _ =>
      throw <| IO.userError s!"expected 'i ec ts' or 'p exited ec ts', got {line}"