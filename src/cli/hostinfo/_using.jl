# hostinfo CLI: kit-internal names in `Main` (see `hostinfo.jl`).
using .DistSSHRun:
    cli_project_disp,
    cli_project_root,
    print_header,
    print_hostinfo
import .DistSSHRun: parse_hostinfo_args, show_hostinfo_usage
