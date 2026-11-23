category: breaking

- `dist_ssh_kit_version`, `parse_pool_args`, and `show_pool_usage` are `public`.
- `kit_process_start_key` is removed in favor of `process_start_key` on DistSSHBase.
- `print_warn`, `print_header`, and `writeln_field` are `public` on `DistSSHBase.CLI`.
- `kit_println` is removed in favor of `cli_println` on `DistSSHBase.CLI`.
- `kit_confirm` is removed in favor of `cli_confirm` on `DistSSHBase.CLI`.
- `KIT_PROGRESS` is removed in favor of `CURRENT_PROGRESS` on `DistSSHBase.CLI`.
- `KIT_PROGRESS_SUSPEND` is removed in favor of `PROGRESS_SUSPEND` on `DistSSHBase.CLI`.
- `KitProgressState` is removed in favor of `ProgressState` on `DistSSHBase.CLI`.
- `kit_progress_done!` is removed in favor of `progress_done!` on `DistSSHBase.CLI`.
- `kit_progress_latest` is removed in favor of `progress_latest` on `DistSSHBase.CLI`.
- `resolve_distributed_output_dir!` is removed in favor of `resolve_output_dir!`.
- The downstream allowlist is empty. `_ssh_host_args`, `_test_doubles_on`, `kit_job_mark_comment`, `kit_job_pkill_pattern`, `CliSharedFlags`, `apply_shared_cli_flags!`, `close_log_file`, `get_local_git_hash`, `kit_verbosity`, `set_kit_verbosity!`, `setup_cli_host_token`, `parse_ride_args`, and `show_ride_usage` are not a downstream contract.
