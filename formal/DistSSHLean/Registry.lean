import DistSSHLean.Registry.Types
import DistSSHLean.DistSSHBase.ShellStatus

namespace DistSSHLean.Registry

def all : List Entry := DistSSHLean.DistSSHBase.ShellStatus.entries

def staticFacts : List String := []

end DistSSHLean.Registry