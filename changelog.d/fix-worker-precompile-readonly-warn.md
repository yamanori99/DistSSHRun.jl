category: fixed

- Worker project precompile on a read-only project directory prints a stderr warning naming the host, worker rank, and project path instead of skipping silently. Precompile failures still warn on stderr and do not stop worker launch.
