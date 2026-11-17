category: added

- Document and pin the 0.2.0 cluster-manager public surface: exported [`LaunchReport`](@ref) accessors, [`HostLaunchFailure`](@ref), rank and seed helpers, [`RunJobConfig`](@ref) / `unsafe_*` names, per-host [`HostLaunchPlan`](@ref) bind/topology helpers, and provenance `launch` / `seeds` shapes. Scoped `cluster(cfg) do` remains 0.2.x ([#464](https://github.com/yamanori99/DistSSHRun.jl/issues/464)); ControlMaster manager implementation is not in 0.2.0.
