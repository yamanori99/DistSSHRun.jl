import DistSSHLean

/-!
Per-theorem axiom report for registry `proven` entries. Run: `lake env lean AxiomReport.lean`.
-/

open Lean Meta DistSSHLean.Registry

def standardAxioms : List Name := [``propext, ``Classical.choice, ``Quot.sound]

def runtimeAxiomModule : Name := `DistSSHLean.Runtime.Axioms

def axiomAllowed (env : Environment) (ax : Name) : Bool :=
  standardAxioms.contains ax ||
    match env.getModuleIdxFor? ax with
    | some idx => env.header.moduleNames[idx.toNat]? == some runtimeAxiomModule
    | none => false

def axiomIsRuntimeExempt (env : Environment) (ax : Name) : Bool :=
  match env.getModuleIdxFor? ax with
  | some idx => env.header.moduleNames[idx.toNat]? == some runtimeAxiomModule
  | none => false

def axiomLabel (env : Environment) (ax : Name) : String :=
  let base := ax.toString
  if axiomIsRuntimeExempt env ax then
    s!"{base} (runtime exempt)"
  else
    base

def shortThm : Name → String
  | .anonymous => "<anonymous>"
  | .str _ s => s
  | .num _ i => toString i

def formatAxiomList (env : Environment) (axioms : Array Name) : String :=
  let sorted := axioms.qsort (fun a b => a.toString < b.toString) |>.toList
  String.intercalate ", " (sorted.map (axiomLabel env))

#eval show MetaM Unit from do
  let env ← getEnv
  let mut problems : Nat := 0
  let mut reported : Std.HashSet Name := {}
  let filtered : List Entry := all.filter fun (e : Entry) =>
    e.status == .proven && e.thm.isSome
  let proven := filtered.toArray.qsort (fun (a b : Entry) => a.id < b.id) |>.toList
  for (e : Entry) in proven do
    let some thm := e.thm | continue
    let some (.thmInfo _) := env.find? thm |
      problems := problems + 1
      IO.println s!"AXIOMS problem: {e.id}: theorem {thm} missing from environment"
      continue
    let axioms ← collectAxioms thm
    for ax in axioms do
      unless axiomAllowed env ax do
        problems := problems + 1
        IO.println s!"AXIOMS problem: {e.id}: {thm} depends on disallowed {ax}"
    IO.println s!"AXIOMS {shortThm thm}: {formatAxiomList env axioms}"
    reported := reported.insert thm
  unless reported.size == proven.length do
    problems := problems + (proven.length - reported.size)
    IO.println s!"AXIOMS problem: proven registry count {proven.length} ≠ reported {reported.size}"
  IO.println s!"AXIOMS theorems {proven.length} problems {problems}"
  unless problems == 0 do
    throwError m!"axiom report failed with {problems} problem(s)"