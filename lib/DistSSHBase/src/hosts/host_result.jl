"""Per-host outcome for sync, ship, and similar multi-host operations."""
struct HostResult
    host::String
    ok::Bool
    message::String
end

public HostResult
