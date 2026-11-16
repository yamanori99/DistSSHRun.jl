category: added

- `CliUsageError`, `cli_parse`, `cli_help_stdout`, `cli_required_else_help`, `CLI_EXIT_USAGE`, and `with_cli_exit` are public on DistSSHBase and are not exported. Kit CLI entry points call them. A parser `ArgumentError` becomes usage (exit 2). A later `ArgumentError` stays a runtime error (exit 1). Ctrl-C returns 130 unless the caller passes another code. An EPIPE `IOError` returns 141 and prints nothing.
