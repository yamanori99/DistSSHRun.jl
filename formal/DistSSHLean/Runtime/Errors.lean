namespace DistSSHLean

/-- Julia exceptions modelled for DistSSHBase (julia-in-lean `DynExpr.Runtime.Errors`). -/
inductive JlError where
  | argumentError (msg : String)
  deriving Repr, DecidableEq

abbrev Jl (α : Type) := Except JlError α

end DistSSHLean