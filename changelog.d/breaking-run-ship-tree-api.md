category: breaking

- Remove Run pack wrappers `ShipSnapshot`, `snapshot`, `snapshot_directory`,
  `snapshot_tar`, Run `content_tree_hash`, and `pack_ship_tar`. Pack with
  `DistSSHShip.pack_tree` / `ShipPack` instead.
- Replace `ship(snapshot, …)` and `ship_project_to_hosts!` with
  `ship_tree!(project, hosts, deploy_root; …)` and
  `ship_tree!(pack, hosts, deploy_root; …)`. Rename keyword `record` →
  `provenance`. `ShipTreeResult.remote_root` → `deploy_root`; drop
  `tree_matches_head`.
- Move [`HostResult`](@ref) to `DistSSHRun.DistSSHBase`; remove
  `DistSSHShip.ShipHostResult` (in-repo lib versions stay lockstep with Run).
