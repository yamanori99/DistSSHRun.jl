"""Default juliaup channel from `juliaup status` (`*` row), or `nothing`."""
function _juliaup_default_channel_from_status(status_out::AbstractString)::Union{Nothing, String}
    for line in split(status_out, '\n'; keepempty = false)
        s = strip(line)
        isempty(s) && continue
        startswith(s, "Default") && continue
        startswith(s, "-") && continue
        m = match(r"^\*\s+(\S+)", s)
        m === nothing && continue
        cap = m.captures[1]
        cap isa AbstractString && return String(cap)
    end
    return nothing
end

"""Installed patch of the `juliaup status` `*` channel, or `-`.

`juliaup status` looks like `*  1.13     1.13.2+0.aarch64…`. Channel-only
`* 1.13` (no Version) is `-`. Named channels (`release`) still use the
Version column.
"""
function _juliaup_patch_from_status(status_out::AbstractString)::String
    for line in eachsplit(String(status_out), '\n'; keepempty = false)
        s = strip(line)
        isempty(s) && continue
        startswith(s, "Default") && continue
        startswith(s, "-") && continue
        m = match(r"^\*\s+\S+\s+(\S+)", s)
        m === nothing && continue
        cap = m.captures[1]
        cap isa AbstractString || continue
        return String(first(split(String(cap), '+'; limit = 2)))
    end
    return "-"
end

"""SSH body: `juliaup status`.

`missing_ok` exits 0 when no juliaup candidate exists. Otherwise that case
exits 127 so a strict reader can tell “absent” from an empty status.
"""
function _juliaup_status_sh(; missing_ok::Bool = true)::String
    words = join(_juliaup_candidate_sh_word.(remote_juliaup_candidates()), " ")
    missing = missing_ok ? "exit 0" : "exit 127"
    return """
    JU=\"\"
    for c in $words; do
      if [ -x \"\$c\" ]; then
        JU=\"\$c\"
        break
      fi
    done
    [ -z \"\$JU\" ] && $missing
    \"\$JU\" status 2>/dev/null
    """
end

"""Installed rows of `juliaup status`. Header and rule lines are dropped."""
function _installed_status_lines(
        status_out::AbstractString;
        channel::Union{Nothing, AbstractString} = nothing,
    )::Vector{String}
    want = channel === nothing ? nothing : String(channel)
    lines = String[]
    for line in eachsplit(String(status_out), '\n'; keepempty = false)
        s = strip(line)
        isempty(s) && continue
        startswith(s, "Default") && continue
        startswith(s, "-") && continue
        if want !== nothing
            parts = split(s)
            startswith(s, "*") && (parts = parts[2:end])
            isempty(parts) && continue
            String(parts[1]) == want || continue
        end
        push!(lines, s)
    end
    return lines
end
