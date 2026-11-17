category: fixed

- Worker shipped-tree verify runs through `Core.eval`. The worker does not need `DistSSHRun` loaded. The hash covers the shipped paths. Files written after extract, and local workers sharing the controller project, are not part of that check.
