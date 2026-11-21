# On-disk record `writer` field: package name and Project.toml version.

module RecordWriterMismatchKind
    const missing = :missing
    const malformed = :malformed
    const package = :package
    const minor = :minor
end

"""Build the `writer` string for a versioned record."""
function record_writer_string(
        package_name::AbstractString,
        version::VersionNumber,
    )::String
    pkg = strip(String(package_name))
    isempty(pkg) && throw(ArgumentError("record writer package name must be non-empty"))
    return string(pkg, ' ', version)
end

function _record_writer_version_rest(s::AbstractString)::Union{Nothing, String}
    rest = strip(String(s))
    isempty(rest) && return nothing
    return rest
end

"""
Parse `writer` into package name and full version string, or `nothing` when malformed.
"""
function parse_record_writer(writer::AbstractString)::Union{Nothing, Tuple{String, String}}
    t = strip(String(writer))
    isempty(t) && return nothing
    i = findfirst(isspace, t)
    i === nothing && return nothing
    pkg = strip(t[1:(i - 1)])
    isempty(pkg) && return nothing
    rest = _record_writer_version_rest(t[i:end])
    rest === nothing && return nothing
    return pkg, rest
end

function _record_writer_version_number(rest::AbstractString)::Union{Nothing, VersionNumber}
    try
        return VersionNumber(String(rest))
    catch
        return nothing
    end
end

"""
`:ok`, `:missing`, `:malformed`, `:package`, or `:minor` for a record's `writer` field.
`expected_version` is this package's version from `Project.toml`.
"""
function record_writer_minor_match(
        writer,
        expected_package::AbstractString,
        expected_version::VersionNumber,
    )::Symbol
    writer === nothing && return RecordWriterMismatchKind.missing
    writer isa AbstractString || return RecordWriterMismatchKind.malformed
    parsed = parse_record_writer(writer)
    parsed === nothing && return RecordWriterMismatchKind.malformed
    pkg, rest = parsed
    pkg == String(expected_package) || return RecordWriterMismatchKind.package
    ver = _record_writer_version_number(rest)
    ver === nothing && return RecordWriterMismatchKind.malformed
    ver.major == expected_version.major && ver.minor == expected_version.minor ||
        return RecordWriterMismatchKind.minor
    return :ok
end

"""`major.minor` for shell embedding (non-negative integers)."""
function record_writer_minor_parts(version::VersionNumber)::Tuple{Int, Int}
    return Int(version.major), Int(version.minor)
end

"""ERE pattern fragment for a quoted TOML `writer = "Pkg x.y.z"` line (exact package, any patch)."""
function record_writer_toml_line_ere(
        package_name::AbstractString,
        version::VersionNumber,
    )::String
    pkg = String(package_name)
    maj, min = record_writer_minor_parts(version)
    pkg_ere = replace(pkg, "." => "\\.")
    return "^writer = \"" * pkg_ere * " " * string(maj) * "\\." * string(min) * "[^\"]*\"\$"
end

"""`major` and `minor` as decimal literals safe for POSIX `sh` (non-negative)."""
function record_writer_shell_minor_words(version::VersionNumber)::Tuple{String, String}
    maj, min = record_writer_minor_parts(version)
    maj < 0 && throw(ArgumentError("record writer shell minor: negative major"))
    min < 0 && throw(ArgumentError("record writer shell minor: negative minor"))
    return string(maj), string(min)
end

"""User-facing sentence for a failed `record_writer_minor_match` (messages layer)."""
function record_writer_mismatch_message(
        kind::Symbol,
        writer,
        expected_package::AbstractString,
        expected_version::VersionNumber;
        fix::AbstractString = "Rewrite or remove the record, then rerun setup or the command that writes it.",
    )::String
    exp = string(expected_package, ' ', expected_version.major, '.', expected_version.minor)
    wshow = writer === nothing ? "(missing)" : string(writer)
    if kind == RecordWriterMismatchKind.missing
        return "record is missing writer (expected $exp). $fix"
    elseif kind == RecordWriterMismatchKind.malformed
        return "record writer is malformed (got $(repr(wshow)); expected $exp). $fix"
    elseif kind == RecordWriterMismatchKind.package
        return "record writer package does not match (got $(repr(wshow)); expected $exp). $fix"
    elseif kind == RecordWriterMismatchKind.minor
        return "record writer version does not match (got $(repr(wshow)); expected $exp). $fix"
    else
        return "record writer rejected (got $(repr(wshow)); expected $exp). $fix"
    end
end

public RecordWriterMismatchKind,
    parse_record_writer,
    record_writer_minor_match,
    record_writer_minor_parts,
    record_writer_mismatch_message,
    record_writer_shell_minor_words,
    record_writer_string,
    record_writer_toml_line_ere
