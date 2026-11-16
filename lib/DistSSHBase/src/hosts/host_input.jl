# Host list sources: CLI, TOML hosts file, Julia machine file (one explicit source).

"""One row from a TOML hosts file (`[[hosts]]`, required `name`)."""
struct TomlHostEntry
    name::String
    workers::Int
    user::Union{Nothing, String}
    port::Union{Nothing, Int}
    bind::Union{Nothing, String}
end

function _toml_int(v, field::String, path::AbstractString)
    v === nothing && return nothing
    try
        i = Int(v)
        i < 1 && throw(ArgumentError("$path: $field must be >= 1"))
        return i
    catch e
        e isa ArgumentError && rethrow(e)
        throw(ArgumentError("$path: $field must be an integer"))
    end
end

function _toml_bind_field(row::Dict{String, Any}, path::AbstractString, index::Int)::Union{Nothing, String}
    haskey(row, "bind") || return nothing
    b = get(row, "bind", nothing)
    b === nothing && return nothing
    s = String(strip(b))
    isempty(s) && throw(ArgumentError("$path: hosts[$index] `bind` is empty"))
    return s
end

"""SSH destination for one TOML hosts row (`user@host` with optional port in tokens)."""
function toml_host_ssh_dest(entry::TomlHostEntry)::String
    dest = entry.name
    user = entry.user
    user !== nothing && !contains(dest, '@') && (dest = string(user, "@", dest))
    tok = format_machine_token(entry.workers, dest; port = entry.port)
    return split_worker_token(tok)[1]
end

"""Parse TOML hosts file into structured rows (file order)."""
function read_toml_host_entries(path::AbstractString; surface::Symbol = :cli)::Vector{TomlHostEntry}
    p = canonical_local_path(path)
    isfile(p) || throw(ArgumentError(explain_hosts_file_not_found(p; surface = surface)))
    data = try
        TOML.parsefile(p)
    catch e
        throw(ArgumentError("$(p): invalid TOML ($(e.msg))"))
    end
    table = get(data, "hosts", nothing)
    table === nothing && throw(ArgumentError("$(p): missing [[hosts]] table"))
    table isa Vector{Any} || throw(ArgumentError("$(p): `hosts` must be a table array"))
    isempty(table) && throw(ArgumentError(explain_hosts_file_empty(p; surface = surface)))
    out = TomlHostEntry[]
    seen = Dict{String, Int}()
    for (i, row) in enumerate(table)
        row isa Dict{String, Any} || throw(ArgumentError("$(p): hosts[$i] must be a table"))
        name = get(row, "name", nothing)
        name === nothing && throw(ArgumentError("$(p): hosts[$i] missing required `name`"))
        name = String(strip(name))
        isempty(name) && throw(ArgumentError("$(p): hosts[$i] `name` is empty"))
        workers = something(_toml_int(get(row, "workers", nothing), "workers", p), 1)
        user = let u = get(row, "user", nothing)
            u === nothing ? nothing : String(strip(u))
        end
        port = _toml_int(get(row, "port", nothing), "port", p)
        bind = _toml_bind_field(row, p, i)
        dest = name
        user !== nothing && !contains(dest, '@') && (dest = string(user, "@", dest))
        tok = format_machine_token(workers, dest; port = port)
        parse_machine_token(tok) # validate
        entry = TomlHostEntry(name, workers, user, port, bind)
        label = machine_ssh_label(parse_machine_token(tok))
        if haskey(seen, label)
            throw(
                ArgumentError(
                    "$(p): duplicate host $(repr(label)) at hosts[$i] and hosts[$(seen[label])]",
                ),
            )
        end
        seen[label] = i
        push!(out, entry)
    end
    return out
end

"""Per-host Distributed bind overrides from a TOML hosts file (`dest` => `bind`)."""
function read_toml_host_bind_overrides(
        path::AbstractString;
        surface::Symbol = :cli,
    )::Dict{String, String}
    out = Dict{String, String}()
    for entry in read_toml_host_entries(path; surface = surface)
        entry.bind === nothing && continue
        dest = toml_host_ssh_dest(entry)
        out[dest] = entry.bind
    end
    return out
end

"""Parse TOML hosts file; returns machine-token strings in file order."""
function read_toml_hosts_file(path::AbstractString; surface::Symbol = :cli)::Vector{String}
    out = String[]
    for entry in read_toml_host_entries(path; surface = surface)
        dest = entry.name
        entry.user !== nothing && !contains(dest, '@') && (dest = string(entry.user, "@", dest))
        tok = format_machine_token(entry.workers, dest; port = entry.port)
        parse_machine_token(tok) # validate
        push!(out, tok)
    end
    return out
end

"""Machine-file lines (strict Julia-style subset)."""
function read_machine_file_lines(path::AbstractString; surface::Symbol = :cli)::Vector{String}
    p = canonical_local_path(path)
    isfile(p) || throw(ArgumentError(explain_hosts_file_not_found(p; surface = surface)))
    out = String[]
    seen = Dict{String, Int}()
    for (lineno, line) in enumerate(readlines(p))
        s = strip(line)
        (isempty(s) || startswith(s, '#')) && continue
        try
            parse_machine_token(s)
        catch e
            e isa ArgumentError || rethrow(e)
            throw(ArgumentError("$(p):$(lineno): $(e.msg)"))
        end
        label = machine_ssh_label(parse_machine_token(s))
        if haskey(seen, label)
            throw(
                ArgumentError(
                    "$(p): duplicate host $(repr(label)) at lines $(seen[label]) and $lineno",
                ),
            )
        end
        seen[label] = lineno
        push!(out, s)
    end
    isempty(out) && throw(ArgumentError(explain_hosts_file_empty(p; surface = surface)))
    return out
end

"""Legacy line hosts file: each non-comment line is one machine token."""
function read_legacy_hosts_file_lines(path::AbstractString; surface::Symbol = :cli)::Vector{String}
    p = canonical_local_path(path)
    isfile(p) || throw(ArgumentError(explain_hosts_file_not_found(p; surface = surface)))
    out = String[]
    for line in readlines(p)
        s = strip(line)
        (isempty(s) || startswith(s, '#')) && continue
        parse_machine_token(s)
        push!(out, s)
    end
    isempty(out) && throw(ArgumentError(explain_hosts_file_empty(p; surface = surface)))
    return out
end

"""Detect TOML hosts file by leading content."""
function hosts_file_is_toml(path::AbstractString)::Bool
    p = canonical_local_path(path)
    isfile(p) || return false
    n = 0
    for line in readlines(p)
        n += 1
        n > 30 && return false
        s = strip(line)
        isempty(s) && continue
        startswith(s, '#') && continue
        return startswith(s, "[[hosts]]") || startswith(s, "[hosts") || occursin("[[hosts]]", s)
    end
    return false
end

function read_hosts_file_lines(path::AbstractString; surface::Symbol = :cli)::Vector{String}
    if hosts_file_is_toml(path)
        return read_toml_hosts_file(path; surface = surface)
    end
    return read_legacy_hosts_file_lines(path; surface = surface)
end