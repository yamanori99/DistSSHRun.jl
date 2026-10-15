"""
juliaup verbs on hosts (`up add`, `up default`, `up update`, `up status`).

Names marked `public` are a contract inside the DistSSH family. A 0.x patch
does not change them.
"""
module DistSSHUp

import DistSSHBase
using .DistSSHBase

include("body.jl")

end # module DistSSHUp
