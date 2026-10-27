category: breaking

- Remote instantiate (`setup --instantiate`, `instantiate!`, and the instantiate step of `go --rsync` / `drive --rsync`) stops, and names `help setup`, when the worker has no reachable registry, when `Pkg.is_manifest_current` is not `true` (a Manifest with no `project_hash` included), or when Manifest `julia_version` is missing or its minor differs from that Julia. It then runs `Pkg.instantiate(; manifest=true, update_registry=false, julia_version_strict=true)`. A missing Manifest is still the error from #219.
