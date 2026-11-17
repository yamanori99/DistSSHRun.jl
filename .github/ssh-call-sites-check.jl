#!/usr/bin/env julia
# Product trees must build SSH argv through DistSSHBase (ssh.jl), not ad hoc -o BatchMode.
#
#   julia --startup-file=no --project=. .github/ssh-call-sites-check.jl
#
# Exit 1 with file:line hints when a forbidden pattern is found.

const ROOT = normpath(joinpath(@__DIR__, ".."))

function _git_jl_files()::Vector{String}
    lines = try
        readchomp(`git -C $ROOT ls-files -- 'src/**/*.jl' 'lib/**/src/**/*.jl'`)
    catch
        String[]
    end
    return isempty(lines) ? String[] : split(lines, '\n'; keepempty = false)
end

function _hint_only_path(path::AbstractString)::Bool
    p = replace(String(path), '\\' => '/')
    occursin("/messages/", p) && return true
    occursin("/DistSSHBase/src/hosts/hosts.jl", p) && return true
    occursin("/core/setup/hosts.jl", p) && return true
    return false
end

function _builder_path(path::AbstractString)::Bool
    return endswith(String(path), "lib/DistSSHBase/src/ssh/ssh.jl")
end

function _scan_batchmode(path::AbstractString, lines::Vector{String})::Vector{String}
    hits = String[]
    _hint_only_path(path) && return hits
    _builder_path(path) && return hits
    for (i, line) in pairs(lines)
        occursin(r"(?i)batchmode", line) || continue
        push!(hits, "$path:$i: $(strip(line))")
    end
    return hits
end

function _scan_raw_ssh_cmd(path::AbstractString, lines::Vector{String})::Vector{String}
    _builder_path(path) && return String[]
    hits = String[]
    for (i, line) in pairs(lines)
        occursin(r"\[\s*\"ssh\"", line) || continue
        occursin("_ssh_cmd", line) && continue
        occursin("_host_tool_cmd", line) && continue
        occursin("_host_tool_exe", line) && continue
        push!(hits, "$path:$i: $(strip(line))")
    end
    return hits
end

function _scan_phase_opts_dup(path::AbstractString, lines::Vector{String})::Vector{String}
    hits = String[]
    for (i, line) in pairs(lines)
        occursin(r"_ssh_phase_opts", line) || continue
        push!(hits, "$path:$i: $(strip(line))")
    end
    return hits
end

function main()
    failures = String[]
    for rel in _git_jl_files()
        path = joinpath(ROOT, rel)
        isfile(path) || continue
        lines = String[split(read(path, String), '\n')...]
        append!(failures, _scan_batchmode(rel, lines))
        append!(failures, _scan_raw_ssh_cmd(rel, lines))
        append!(failures, _scan_phase_opts_dup(rel, lines))
    end
    if isempty(failures)
        println("ssh-call-sites-check: ok")
        return
    end
    for f in failures
        println(f)
    end
    return exit(1)
end

main()
