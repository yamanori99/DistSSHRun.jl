category: breaking

- `dist_ssh_kit_version`, `parse_pool_args`, and `show_pool_usage` are `public`.
- `kit_process_start_key` is removed in favor of `process_start_key` on DistSSHBase.
- `print_warn`, `kit_println`, `print_header`, `writeln_field`, `kit_confirm`, `KIT_PROGRESS`, `KIT_PROGRESS_SUSPEND`, `KitProgressState`, `kit_progress_done!`, and `kit_progress_latest` are `public` on `DistSSHBase.CLI`.
- `resolve_distributed_output_dir!` is removed in favor of `resolve_output_dir!`.
- The downstream allowlist is empty. `_ssh_host_args`, `_test_doubles_on`, `kit_job_mark_comment`, `kit_job_pkill_pattern`, `CliSharedFlags`, `apply_shared_cli_flags!`, `close_log_file`, `get_local_git_hash`, `kit_verbosity`, `set_kit_verbosity!`, `setup_cli_host_token`, `parse_ride_args`, and `show_ride_usage` are not a downstream contract.
