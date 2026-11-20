# Runtime unsafe opt-ins: warn once, record provenance.

const _UNSAFE_SKIP_ENV_DIGESTS = Ref(false)
const _UNSAFE_EXPOSE_PORT = Ref(false)
const _UNSAFE_ALL_TO_ALL = Ref(false)

"""
Whether `--unsafe-skip-env-digests` / [`RunJobConfig`](@ref) waiver is active in this process.

Set for the duration of [`with_unsafe_skip_env_digests`](@ref) or
[`with_run_unsafe_options!`](@ref).
"""
function unsafe_skip_env_digests_active()::Bool
    return _UNSAFE_SKIP_ENV_DIGESTS[]
end

"""Whether non-loopback Distributed bind is allowed (`--unsafe-expose-port`)."""
function unsafe_expose_port_active()::Bool
    return _UNSAFE_EXPOSE_PORT[]
end

"""Whether worker-to-worker links are allowed (`--unsafe-all-to-all`)."""
function unsafe_all_to_all_active()::Bool
    return _UNSAFE_ALL_TO_ALL[]
end

function _announce_unsafe!(label::AbstractString, msg::AbstractString)
    @warn string("unsafe: ", msg)
    return _note_provenance_unsafe!(label)
end

"""Run `f` with the Manifest/Project digest waiver enabled when `enabled` is true."""
function with_unsafe_skip_env_digests(f::Function, enabled::Bool)
    enabled || return f()
    old = _UNSAFE_SKIP_ENV_DIGESTS[]
    _UNSAFE_SKIP_ENV_DIGESTS[] = true
    try
        _announce_unsafe!(
            "skip_env_digests",
            "Manifest/Project byte digests may differ; Julia build and DistSSH* versions must still match",
        )
        _record_environment_unverified!("unsafe-skip-env-digests")
        return f()
    finally
        _UNSAFE_SKIP_ENV_DIGESTS[] = old
    end
end

"""Run `f` with non-loopback worker bind allowed when `enabled` is true."""
function with_unsafe_expose_port(f::Function, enabled::Bool)
    enabled || return f()
    old = _UNSAFE_EXPOSE_PORT[]
    _UNSAFE_EXPOSE_PORT[] = true
    try
        _announce_unsafe!("expose_port", "non-loopback Distributed bind is enabled")
        return f()
    finally
        _UNSAFE_EXPOSE_PORT[] = old
    end
end

"""Run `f` with worker-to-worker topology allowed when `enabled` is true."""
function with_unsafe_all_to_all(f::Function, enabled::Bool)
    enabled || return f()
    old = _UNSAFE_ALL_TO_ALL[]
    _UNSAFE_ALL_TO_ALL[] = true
    try
        _announce_unsafe!("all_to_all", "worker-to-worker connections are enabled")
        return f()
    finally
        _UNSAFE_ALL_TO_ALL[] = old
    end
end

"""CLI argv fragment for the env-digest waiver; empty when `enabled` is false."""
function unsafe_skip_env_digests_argv(enabled::Bool)::Vector{String}
    enabled || return String[]
    return String["--unsafe-skip-env-digests"]
end

"""
Run `f` with resolved [`RunJobConfig`](@ref) unsafe flags applied for this process.

Drive, ride, and go call this around worker launch.
"""
function with_run_unsafe_options!(f::Function, cfg::RunJobConfig)
    return with_unsafe_skip_env_digests(cfg.unsafe_skip_env_digests.value) do
        with_unsafe_expose_port(cfg.unsafe_expose_port.value) do
            with_unsafe_all_to_all(cfg.unsafe_all_to_all.value) do
                return f()
            end
        end
    end
end

public unsafe_all_to_all_active, unsafe_expose_port_active, unsafe_skip_env_digests_active, unsafe_skip_env_digests_argv
public with_run_unsafe_options!, with_unsafe_all_to_all, with_unsafe_expose_port, with_unsafe_skip_env_digests
