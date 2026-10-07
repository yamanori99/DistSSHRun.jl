# Up CLI: kit-internal names in `Main` (see `up.jl`).
using .DistSSHRun:
    finish_host_op!,
    juliaup_align_remotes,
    juliaup_update_remotes,
    juliaup_verb_remotes,
    kit_println,
    parse_up_args,
    preflight_setup_ssh,
    print_err,
    println_fatal,
    setup_juliaup_ssh_hosts,
    show_up_usage,
    validate_setup_hosts
