"""
Worker sizing.

Names marked `public` are a contract inside the DistSSH family. A 0.x patch
does not change them.
"""
module DistSSHSize

import DistSSHBase
using .DistSSHBase

include("body.jl")

end # module DistSSHSize
