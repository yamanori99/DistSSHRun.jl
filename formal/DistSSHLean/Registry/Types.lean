import Lean

namespace DistSSHLean.Registry

inductive Status where
  | todo
  | stuck
  | proven
  | refuted
  deriving Repr, BEq, DecidableEq

structure Entry where
  id : String
  juliaFile : String
  juliaFns : List String
  statement : String
  preconditions : String
  status : Status
  prop : Lean.Name
  thm : Option Lean.Name := none
  notes : String := ""

end DistSSHLean.Registry