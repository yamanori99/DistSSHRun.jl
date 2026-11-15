# Host lists and worker counts. Placement grammar stays in hosts.jl.

"""Split a `--hosts` / `DISTSSH_HOSTS` CSV into tokens (empty pieces dropped)."""
function split_hosts_csv(raw::AbstractString)::Vector{String}
    out = String[]
    for h in split(String(raw), ',')
        s = strip(h)
        !isempty(s) && push!(out, s)
    end
    return out
end

"""
Parse a machine token into `(ssh_dest, workers_or_nothing)`.

`setup` / `hostinfo` use the destination only. Legacy `host:N` is rejected.
"""
function split_worker_token(spec::AbstractString)::Tuple{String, Union{Nothing, Int}}
    p = parse_machine_token(spec)
    n = p.workers == 1 ? nothing : p.workers
    return p.dest, n
end

"""
    host_tokens(hosts::AbstractVector{<:AbstractString}) -> Vector{String}
    host_tokens(hosts::AbstractVector{Tuple{String,Union{Int,Nothing}}})
    host_tokens(parsed; kind::Symbol) -> Vector{String}

Rebuild CLI host tokens for `execute!`.

Go tokens are the parser strings. Ride uses the same shape. Drive uses remote
tuple specs only (local workers use `--local-workers`, not tokens). `kind` must be `:go`,
`:drive`, or `:ride`.
"""
function host_tokens(hosts::AbstractVector{<:AbstractString})::Vector{String}
    return String[String(h) for h in hosts]
end

function host_tokens(
        hosts::AbstractVector{Tuple{String, Union{Int, Nothing}}},
    )::Vector{String}
    specs = String[]
    # Local workers are not encoded as placement tokens (see --local-workers).
    for pair in hosts
        host = pair[1]
        n = something(pair[2], 1)
        push!(specs, format_machine_token(n, host))
    end
    return specs
end

function host_tokens(parsed; kind::Symbol)::Vector{String}
    if kind === :go || kind === :ride
        return host_tokens(parsed.hosts::AbstractVector{<:AbstractString})
    elseif kind === :drive
        return host_tokens(parsed.hosts::AbstractVector{Tuple{String, Union{Int, Nothing}}})
    end
    throw(ArgumentError("host_tokens: kind must be :go, :drive, or :ride, got $(repr(kind))"))
end

"""SSH host names from a hosts file (for setup / DistSSHSession)."""
function read_hosts_file(
        path::AbstractString;
        surface::Symbol = :cli,
    )::Vector{String}
    return [split_worker_token(line)[1] for line in read_hosts_file_lines(path; surface = surface)]
end
