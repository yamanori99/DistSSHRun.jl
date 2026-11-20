category: breaking

- Non-interactive SSH is enforced end-to-end: every kit `ssh` / `scp` goes through DistSSHBase (`build_ssh_opts`, `run_ssh` with a Julia-side auth budget, `SSH_ASKPASS_REQUIRE=never`). `DISTRIBUTED_SSH_OPTS` cannot override `BatchMode=yes` or `RequestTTY=no`. Drive and ride run SSH preflight before worker join; zero joined workers fail closed on drive, ride, and `add_drive_workers!`. The push gate diff-lints added product lines for ad hoc `BatchMode` / raw `ssh` argv (`scripts/lint/ssh-argv.sh`, #462).
