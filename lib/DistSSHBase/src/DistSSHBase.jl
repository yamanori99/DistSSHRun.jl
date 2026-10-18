"""
Host naming, SSH, paths, and help chrome shared by the DistSSH packages.

Internal to the DistSSH family. Not registered. DistSSHRun includes this
source as `DistSSHRun.DistSSHBase`. Names marked `public` are a contract
inside the DistSSH family. A 0.x patch does not change them.
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
include("sigint.jl")
include("help.jl")
include("ssh.jl")
include("julia_where.jl")
include("namespace.jl")

# Queue and Kit import these. Underscore names stay private.
public PARENT_HOST_NAME
public cli_entry, cli_heading, cli_m, cli_m_project, cli_qhost, cli_qhost_heading
public format_placement_token, get_remote_julia_version, is_sigint, julia_project_rel
public parse_placement_token, remote_env_project_root, resolve_remote_julia
public resolve_remote_project_root, shield_sigint, with_cli_entry, without_cancel

end # module DistSSHBase
