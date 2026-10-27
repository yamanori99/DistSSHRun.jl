category: fixed

- `drive` writes the planned SSH hosts to `kit.hosts` before workers join, then replaces that list with the hosts that joined. The file is removed when none joined. An interrupt or other error during join leaves the planned list, so `terminate!` outside Queue can reap those workers.
