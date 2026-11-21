import DistSSHLean.Registry.Types
import DistSSHLean.DistSSHBase.ShellStatus
import DistSSHLean.DistSSHBase.PosixQuote.Proofs

namespace DistSSHLean.Registry

def all : List Entry :=
  DistSSHLean.DistSSHBase.ShellStatus.entries ++ DistSSHLean.DistSSHBase.PosixQuote.entries

def staticFacts : List String := []

end DistSSHLean.Registry