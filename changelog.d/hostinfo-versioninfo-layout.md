category: breaking

- `hostinfo` prints a per-host labeled layout inspired by
  `InteractiveUtils.versioninfo` instead of a single horizontal line.
  `DistSSHBase.HostFacts` adds product OS fields, kernel release, CPU
  architecture, and optional CPU model; missing values stay `-`.
  `print_hostinfo` lives in DistSSHBase next to collection; the Run CLI
  still owns argv and session host lists.
