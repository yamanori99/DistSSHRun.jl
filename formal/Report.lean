import DistSSHLean
import DistSSHLean.Registry.Generality

open Lean Meta DistSSHLean.Registry

#eval show MetaM Unit from do
  for e in DistSSHLean.Registry.all do
    let status := match e.status with
      | .todo => "todo" | .stuck => "stuck" | .proven => "proven" | .refuted => "refuted"
    let clean (s : String) := (s.replace "\t" " ").replace "\n" " "
    let n ← countForallData 6 (mkConst e.prop)
    let kind := if staticFacts.contains e.id then "static" else "general"
    IO.println s!"{e.id}\t{status}\t{kind}\t{n}\t{e.juliaFile}\t{clean e.statement}\t{clean e.preconditions}"