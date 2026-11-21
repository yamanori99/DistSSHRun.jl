# One-shot process environment for job defaults (issue #463 proposal 1).

"""Immutable copy of job-default environment variables for one kit invocation."""
struct ProcessEnv
    data::Dict{String, String}
end

function ProcessEnv(src::AbstractDict{<:Any, <:Any})
    return ProcessEnv(Dict{String, String}(String(k) => String(v) for (k, v) in src))
end

"""Copy the current process `ENV` for parsers and option resolution."""
function snapshot_process_env()::ProcessEnv
    return ProcessEnv(ENV)
end

Base.get(pe::ProcessEnv, key::Union{AbstractString, Symbol}, default) =
    get(pe.data, String(key), default)
Base.get(pe::ProcessEnv, key::Union{AbstractString, Symbol}) = get(pe.data, String(key))
Base.haskey(pe::ProcessEnv, key) = haskey(pe.data, String(key))

const _INVOCATION_PROCESS_ENV = Ref{Union{Nothing, ProcessEnv}}(nothing)

"""Active job-default env for this invocation (`nothing` until a public entry sets it)."""
function invocation_process_env()::ProcessEnv
    pe = _INVOCATION_PROCESS_ENV[]
    pe === nothing && return snapshot_process_env()
    return pe
end

"""Run `f` with `env` as the active invocation snapshot (nested calls restore the outer snapshot)."""
function with_kit_invocation_env!(env::ProcessEnv, f)
    prev = _INVOCATION_PROCESS_ENV[]
    _INVOCATION_PROCESS_ENV[] = env
    try
        return f()
    finally
        _INVOCATION_PROCESS_ENV[] = prev
    end
end
