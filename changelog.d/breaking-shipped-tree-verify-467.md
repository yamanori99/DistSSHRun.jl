category: breaking

- At the end of `go!`, the controller source tree is compared to the active ship-tree deploy record the same way as `drive`, and any drift is recorded under `provenance.shipped_tree_drift`.
- When the controller tree drifted after ship, the user-visible notice is a single `kit_println` line (no duplicate `@warn`).