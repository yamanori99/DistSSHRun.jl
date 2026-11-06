category: breaking

- `up` and `setup --juliaup` run `juliaup update` even when the channel name already matches. `setup --check` fails on a Julia patch or prerelease difference. `--ignore-julia-version` turns that skew into a warning. A build-only difference still passes. `go` and `drive` compare the full VERSION string and the Julia commit.
