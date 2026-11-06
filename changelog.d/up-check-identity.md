category: breaking

- `up` and `setup --juliaup` run `juliaup update` even when the channel name already matches. `setup --check` fails on a Julia patch or prerelease difference, matching the `go` and `drive` version string. `--ignore-julia-version` turns that skew into a warning. A build-only difference still passes.
