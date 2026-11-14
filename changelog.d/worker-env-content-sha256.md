category: breaking

- `drive`, `ride`, and `go` compare raw SHA-256 digests of the resolved
  Manifest and Project files between the controller (master) and every worker
  or go slot before work runs (same definition as the deploy record). Comparison
  is byte-exact; CRLF differences count. A missing worker snapshot or a missing
  digest when the job has a Manifest is an error.
- `--allow-mismatch` is removed. Use `--unsafe-heterogeneous` to waive only
  Manifest and Project byte digests (recorded as unverified). Julia build and
  DistSSH* versions stay mandatory. The flag prints an `unsafe:` warning and
  records `heterogeneous` in provenance.
- Go remote identity probing uses `julia --project=` on the selected project
  tree instead of reading Manifest names only under the deploy root.
