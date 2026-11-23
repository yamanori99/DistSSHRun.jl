import DistSSHLean.DistSSHBase.PosixQuote.Parser

open DistSSHLean.DistSSHBase.PosixQuote

def main (args : List String) : IO Unit := do
  let s := args.getD 0 ""
  match shParseWord (posixQuoteOk s) with
  | none => IO.println "none"
  | some w => IO.println w