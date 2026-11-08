category: breaking

- `hostinfo` prints a per-host labeled layout inspired by
  `InteractiveUtils.versioninfo` instead of a single horizontal line.
  `DistSSHBase.HostFacts` / `collect_host_facts` add product OS fields,
  kernel release, CPU architecture, and optional CPU model; missing
  values stay `-`. `print_hostinfo` stays in DistSSHRun.
