using .DistSSHBase
using .DistSSHBase: PARENT_HOST_NAME, _host_sync_remote_shell_cmd,
    _juliaup_candidate_sh_word, _local_julia_beside_juliaup, posix_quote,
    _remote_shell_path_word, clear_detect_julia_path_cache!, detect_julia_path,
    find_local_juliaup, local_juliaup_candidates, parse_julia_version_full,
    remote_juliaup_candidates

include("version.jl")
include("status.jl")
include("remote.jl")
include("local.jl")
include("hosts.jl")

public juliaup_add_host!, juliaup_default_host!, juliaup_default_patch
public juliaup_status_lines, juliaup_update_host!
