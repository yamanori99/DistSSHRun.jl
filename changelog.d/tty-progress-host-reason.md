category: fixed

- At `:progress`, `setup --check` and SSH preflight failure lines name the host and keep a one-line reason. `go` exit failures release the item bar before the error line so the phase bar does not redraw over it. `:verbose` and pipe output stay the same.
- SSH preflight kit-log lines use one host prefix per result under `:progress` and `:quiet` (no advance `kit_print` prefix). The CLI summary `SSH preflight failed…` ends with a newline so later output does not glue onto that line.
