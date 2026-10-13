"""
Host naming, SSH, paths, and help chrome shared by the DistSSH packages.

Internal to the DistSSH family. Not registered. DistSSHRun includes this
source as `DistSSHRun.DistSSHBase`. No compatibility promise beyond the names
DistSSHRun exports.
"""
module DistSSHBase

import SHA

export canonical_local_path, resolve_pkg_env, resolve_pkg_project_dir, short_path
export host_tokens, is_parent_host_name
export print_colored, print_help_blank, print_help_chrome, print_help_lines, print_help_section
export cache_file, cache_path, cache_relpath, file_sha256, stored_path
export resolve_controller_julia, run_on_host, ssh_opts

include("paths.jl")
include("explain.jl")
include("argv.jl")
include("hosts.jl")
include("host_tokens.jl")
include("cli_entry.jl")
include("help.jl")
include("ssh.jl")
include("julia_where.jl")
include("namespace.jl")

end # module DistSSHBase
