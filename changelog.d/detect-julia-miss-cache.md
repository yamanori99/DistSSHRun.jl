category: fixed

- `DistSSHBase.detect_julia_path` caches a found remote Julia path only.
  A miss (`nothing`) is not cached, so a later call in the same process can
  succeed after the remote or test environment changes (SSH transport and
  non-POSIX shell failures are still not cached).
