category: breaking

- Drive worker heartbeat lives in `lib/DistSSHHeartbeat` and is eval'd into
  `Main.DistSSHHeartbeat` on workers from Run's copy when self-exit is
  enabled, not from a DistSSHRun in the job Manifest. The controller
  (master) no longer defines heartbeat helpers in `Main`. When the opt-in
  monitor is on, a worker that hears nothing from pid 1 for the configured
  deadline exits with status 75 (`EX_TEMPFAIL`) instead of 0. See
  `changelog.d/heartbeat-self-exit-opt-in.md` for defaults.
  A worker stall longer than twice the ping interval no longer trips a
  false-positive exit while the master is healthy. The `_exit` fallback
  after a 10 second `Timer` stays until a Julia 1.13.x with the
  Distributed.jl #198 backport ships.
