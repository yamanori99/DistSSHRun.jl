"""
Host naming, SSH, paths, and help chrome shared by the DistSSH packages.

Internal to the DistSSH family. Not registered. DistSSHRun includes this
source as `DistSSHRun.DistSSHBase`. Names marked `public` are a contract
inside the DistSSH family. A 0.x patch does not change them.
"""
module DistSSHBase

import SHA
import TOML

export build_ssh_opts, canonical_local_path, resolve_pkg_env, resolve_pkg_project_dir, short_path
export run_ssh, ssh_auth_timeout_seconds, ssh_phase_argv, ssh_wait_process!
export host_tokens, is_parent_host_name, throw_removed_parent_placement_token!
export print_colored, print_help_blank, print_help_chrome, print_help_lines, print_help_section
export cache_file, cache_path, cache_relpath, file_sha256, stored_path
export LEGACY_LOCAL_STATE_DIR, LOCAL_STATE_DIR
export is_local_state_dir_name, local_state_dir_names, local_state_relpath
export local_state_write_root, resolve_local_state_dir, resolve_local_state_dir_name
export resolve_local_state_item, resolve_remote_state_item
export remote_cache_dir, resolve_remote_cache_dir
export resolve_controller_julia, run_on_host, ssh_opts
export ProcessRow, processes_with_env, reap!, wait_gone
export cancel!

"""Generic cancel. DistSSHRun and DistSSHQueue add methods."""
function cancel! end

# Include order matches pre-layout dependency order (paths before cores that use them).
include("ssh/paths.jl")
include("ssh/state_dir.jl")
include("messages/explain.jl")
include("argv/cursor.jl")
include("hosts/hosts.jl")
include("hosts/machine.jl")
include("hosts/host_input.jl")
include("hosts/host_tokens.jl")
include("messages/cli_entry.jl")
include("ssh/sigint.jl")
include("messages/cli_exit.jl")
include("ssh/shell_status.jl")
include("env.jl")
include("ssh/budgets.jl")
include("messages/help.jl")
include("ssh/ssh.jl")
include("ssh/worker_endpoint.jl")
include("hosts/hostinfo.jl")
include("hosts/host_result.jl")
include("ssh/julia_where.jl")
include("procs/list.jl")
include("procs/start_key.jl")
include("procs/reap.jl")
include("cli.jl")
include("namespace.jl")
include("component_src.jl")
include("component_id.jl")
include("record_writer.jl")
include("tool_require.jl")

# Queue and Kit import these. Underscore names stay private.
public PARENT_HOST_NAME
public cli_entry, cli_heading, cli_m, cli_m_project, cli_qhost, cli_qhost_heading
public format_machine_token,
    format_placement_token,
    get_remote_julia_version,
    get_remote_julia_version_full,
    is_sigint
public HostFacts, HostResult, collect_host_facts
public current_project_file,
    julia_default_sysimage_path,
    julia_project_rel,
    julia_sysimage_is_default,
    julia_sysimage_path,
    local_preferences_path,
    manifest_path,
    parse_julia_version_full
public MachinePlacement, machine_ssh_endpoint, parse_machine_token, parse_ssh_endpoint
public ssh_connection_ssh_opts
public join_explained_message, machine_ssh_label, throw_legacy_machine_token
public parse_placement_token, posix_quote, remote_env_project_root, resolve_remote_julia
public resolve_remote_project_root, shell_status, shield_sigint, with_cli_entry, without_cancel
public process_start_key
public CLI
public CLI_EXIT_USAGE, CliForegroundInterrupt, CliUsageError, cli_help_stdout, cli_parse, cli_required_else_help, with_cli_exit
public wait_seconds
public tool_require
public src_component_digest
public RecordWriterMismatchKind,
    parse_record_writer,
    record_writer_minor_match,
    record_writer_minor_parts,
    record_writer_mismatch_message,
    record_writer_shell_minor_words,
    record_writer_string,
    record_writer_toml_line_ere

end # module DistSSHBase
