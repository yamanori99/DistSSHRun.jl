category: added

- Export [`cluster`](@ref) and [`Cluster`](@ref): `cluster(session) do c … end` launches workers from a session, tears down DistSSH-started workers on every exit path, leaves user `addprocs` workers connected, and records the launch [`LaunchReport`](@ref) in provenance.
