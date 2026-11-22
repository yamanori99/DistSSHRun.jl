category: fixed

- Public library entry points restore `DISTRIBUTED_PROJECT_ROOT` and `DISTSSH_CLI_SUBCOMMAND_DONE` when they return or throw, so a later `main()` in the same Julia process still runs.