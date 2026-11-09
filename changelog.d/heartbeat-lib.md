category: breaking

- Drive worker heartbeat lives in `lib/DistSSHHeartbeat` and is always
  eval'd into `Main.DistSSHHeartbeat` on workers from Run's copy, not from
  a DistSSHRun in the job Manifest. The master no longer defines heartbeat
  helpers in `Main`. A worker that hears nothing from pid 1 for the
  deadline (default 600 seconds, also the longest the master may go
  without yielding) exits with status 75 (`EX_TEMPFAIL`) instead of 0.
  A worker stall longer than twice the ping interval no longer trips a
  false-positive exit while the master is healthy. The `_exit` fallback
  after a 10 second `Timer` stays until a Julia 1.13.x with the
  Distributed.jl #198 backport ships.
- Supported Julia is **1.13.3+** (`Project.toml` `julia = "1.13.3"` on
  DistSSHRun, DistSSHHeartbeat, DistSSHBase, DistSSHUp, DistSSHShip, and
  docs). 1.13.0–1.13.2 no longer resolve.
