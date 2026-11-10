category: changed

- In-repo packages `DistSSHBase`, `DistSSHUp`, `DistSSHShip`, and
  `DistSSHHeartbeat` are not registered in General. They ship with
  DistSSHRun and now share Run's `version`. Sibling `[compat]` entries use
  an exact `=` pin on the numeric triple (for example `=0.2.0` while Run is
  `0.2.0-DEV`). CI rejects drift; `./.github/version-cut.sh --lockstep-write`
  is the supported way to bump Run and all libs together on a release cut.
