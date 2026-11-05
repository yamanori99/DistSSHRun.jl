category: added

- `CliUsageError`, `cli_parse`, and `with_cli_exit` are public on DistSSHBase and are not exported. No command calls them yet. A parser `ArgumentError` becomes usage (exit 2). A later `ArgumentError` stays a runtime error (exit 1). Ctrl-C returns 130 unless the caller passes another code. An EPIPE `IOError` returns 141 and prints nothing.
