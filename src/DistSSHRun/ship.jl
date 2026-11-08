# Tar ship of a project tree into `<remote_root>/runs/<run_id>/src/`.

const SHIP_MAX_BYTES_DEFAULT = 256 * 1024 * 1024
const SHIP_FILE_WARN_BYTES = 50 * 1024 * 1024
const SHIP_WARN_TOTAL_BYTES_DEFAULT = 100 * 1024 * 1024
const _SHIP_WARN_FILE_ENV = "DISTSSHKIT_SHIP_WARN_FILE_BYTES"
const _SHIP_WARN_TOTAL_ENV = "DISTSSHKIT_SHIP_WARN_TOTAL_BYTES"

const _LAST_SHIP = Ref{Union{Nothing, Dict{String, Any}}}(nothing)
const _SHIP_LAYOUT_ACTIVE = Ref(false)
const _SSHFLAGS_WARNED = Ref(false)

"""
Tar built by [`snapshot`](@ref) and sent by [`ship`](@ref).

[`snapshot_directory`](@ref) is the temporary directory the caller deletes.
[`snapshot_tar`](@ref) is the `ship.tar` inside it.
[`content_tree_hash`](@ref) is the `git-sha1` tree hash recorded when the tar
was built. Fields are not API.
"""
struct ShipSnapshot
    directory::String
    tar_path::String
    content_tree_hash::String
    bytes::Int
    files::Int
    # `nothing`: the tar is not compared to a git tree.
    tree_matches_head::Union{Nothing, Bool}
    external_symlinks_allowed::Bool
    # Resolved project directory the tar was packed from.
    root::String
    # `snapshot` argument, used for the confirm line.
    local_root::String
end
public ShipSnapshot

"""
Result of [`ship`](@ref) and `ship_project_to_hosts!`.

[`result_content_tree_hash`](@ref) and [`result_remote_run_id`](@ref) read
the ship hash and the remote `runs/<run_id>/` id. Fields are not API.
"""
struct ShipTreeResult
    run_id::String
    remote_root::String
    src::String
    content_tree_hash::String
    algorithm::String
    bytes::Int
    files::Int
    # `nothing`: `--ship-tree` does not compare the tar to a git tree.
    # Schema 1 `run.toml` does not carry this field.
    tree_matches_head::Union{Nothing, Bool}
    external_symlinks_allowed::Bool
    host_results::Vector{HostResult}
    cancelled::Bool
end
public ShipTreeResult

function last_ship_result()::Union{Nothing, Dict{String, Any}}
    return _LAST_SHIP[]
end

# `snapshot_select.jl` replaces this so clear also drops active selection.
const _CLEAR_SELECTION_HOOK = Ref{Any}(() -> nothing)

function _clear_last_ship!()
    _LAST_SHIP[] = nothing
    _SHIP_LAYOUT_ACTIVE[] = false
    _CLEAR_SELECTION_HOOK[]()
    return nothing
end

"""`runs/<run_id>/src` from the last successful ship in this process, else `nothing`."""
function _shipped_src()::Union{Nothing, String}
    _SHIP_LAYOUT_ACTIVE[] || return nothing
    rec = last_ship_result()
    rec === nothing && return nothing
    src = get(rec, "src", nothing)
    src isa AbstractString || return nothing
    s = String(src)
    return isempty(strip(s)) ? nothing : s
end

function _record_host_alias(host::AbstractString)::String
    s = String(host)
    at = findlast('@', s)
    at === nothing && return s
    rest = s[(nextind(s, at)):end]
    return isempty(rest) ? s : rest
end

function _throw_rsync_removed()
    throw(ArgumentError(RSYNC_REMOVED_MSG))
end

function _ship_unshippable(path::AbstractString)::Bool
    islink(path) && return false
    isdir(path) && return false
    isfile(path) && return false
    return true
end

const _SHIP_IGNORED_PROJECT_NAMES = (
    "Project.toml",
    "JuliaProject.toml",
    "Manifest.toml",
    "JuliaManifest.toml",
)

"""One line when a project or Manifest file under `root` is left out of `listed`."""
function _warn_excluded_ship_project_files!(root::AbstractString, listed::Vector{String})
    root_c = canonical_local_path(root)
    present = Set{String}(replace(String(rel), '\\' => '/') for rel in listed)
    hits = String[]
    stack = String[root_c]
    while !isempty(stack)
        cur = pop!(stack)
        names = try
            readdir(cur; join = false, sort = false)
        catch
            continue
        end
        for name in names
            name == ".git" && continue
            name == ".distsshkit" && continue
            child = joinpath(cur, name)
            rel = replace(relpath(child, root_c), '\\' => '/')
            if name in _SHIP_IGNORED_PROJECT_NAMES && (isfile(child) || islink(child))
                rel in present || push!(hits, rel)
            end
            isdir(child) && !islink(child) && push!(stack, child)
        end
    end
    isempty(hits) && return nothing
    sort!(unique!(hits))
    shown = join(hits, ", ")
    noun = length(hits) == 1 ? "file is" : "files are"
    print_warn("Warning: $shown $noun excluded by .gitignore and will not be shipped.\n")
    return nothing
end

"""Directory `--ship-tree` walks. The project directory, not the Manifest directory."""
function _ship_tree_root(local_root::AbstractString)::String
    return resolve_pkg_env(canonical_local_path(local_root)).project_dir
end

function _path_outside_ship_root(path::AbstractString, root::AbstractString)::Bool
    rel = replace(relpath(canonical_local_path(path), canonical_local_path(root)), '\\' => '/')
    return rel == ".." || startswith(rel, "../")
end

function _collect_ship_manifest_paths!(found::Vector{Tuple{String, String}}, deps)
    deps isa AbstractDict || return found
    for (name, entry) in deps
        tables = if entry isa AbstractDict
            Any[entry]
        elseif entry isa AbstractVector
            Any[t for t in entry if t isa AbstractDict]
        else
            continue
        end
        for tab in tables
            raw = get(tab, "path", nothing)
            raw isa AbstractString || continue
            s = strip(String(raw))
            isempty(s) && continue
            push!(found, (String(name), s))
        end
    end
    return found
end

"""`(name, path)` for Manifest deps that name a `path` (format 1 or 2)."""
function _ship_manifest_path_deps(manifest_file::AbstractString)::Vector{Tuple{String, String}}
    data = TOML.parsefile(String(manifest_file))
    found = Tuple{String, String}[]
    if haskey(data, "manifest_format")
        _collect_ship_manifest_paths!(found, get(data, "deps", nothing))
    else
        _collect_ship_manifest_paths!(found, data)
    end
    unique!(found)
    return found
end

function _warn_ship_manifest_paths!(manifest::AbstractString, root::AbstractString)
    for (name, raw) in _ship_manifest_path_deps(manifest)
        if isabspath(expanduser(raw))
            print_warn(
                "Warning: Manifest path $raw for $name is absolute and is not part of the ship.\n",
            )
            continue
        end
        location = _resolved_source_path(manifest, raw)
        _path_outside_ship_root(location, root) || continue
        print_warn(
            "Warning: Manifest path $location for $name is outside the ship root and will not be shipped.\n",
        )
    end
    return nothing
end

"""
Warn when the Manifest or a relative path dependency sits outside `root`.

An absolute `[sources]` path still throws. Those workers resolve on their
own filesystem. `go` and `rsync_send_list` are unchanged.
"""
function _warn_ship_outside!(user_path::AbstractString, root::AbstractString)
    given = canonical_local_path(user_path)
    env = resolve_pkg_env(given)
    _require_manifest!(given)
    root_c = canonical_local_path(root)
    root_real = ispath(root_c) ? canonical_local_path(realpath(root_c)) : root_c
    manifest = env.manifest
    if manifest isa String
        if _path_outside_ship_root(manifest, root_c)
            print_warn("Warning: Manifest $manifest is outside the ship root and will not be shipped.\n")
        else
            target = manifest_link_target(manifest)
            if !_path_is_under(target, root_real)
                print_warn(
                    "Warning: Manifest $manifest points at $target, outside the ship root, and will not be shipped.\n",
                )
            end
            _warn_ship_manifest_paths!(String(manifest), root_c)
        end
    end
    project_file = _located_project_file(root_c)
    project_file isa String || return nothing
    for (name, raw) in _project_path_sources(project_file)
        if isabspath(expanduser(raw))
            throw(
                ArgumentError(
                    "Source path $raw for $name is absolute. Workers resolve it on their own filesystem, so it would not be the staged tree.",
                ),
            )
        end
        location = _resolved_source_path(project_file, raw)
        if _path_outside_ship_root(location, root_c)
            print_warn(
                "Warning: Source path $location for $name is outside the ship root and will not be shipped.\n",
            )
            continue
        end
        _ensure_one_path_dep!(name, raw, project_file, root_c, root_real; git = false)
    end
    return nothing
end

"""Tar member paths for one walk of `root`. Does not warn."""
function _ship_members_from_walk(
        root::AbstractString,
        send_list::Vector{String},
    )::Vector{String}
    rels = String[replace(r, '\\' => '/') for r in send_list]
    extras = String[]
    for rel in rels
        d = dirname(rel)
        while !isempty(d) && d != "." && d != "/"
            push!(extras, d)
            d = dirname(d)
        end
    end
    out = unique!(vcat(rels, extras))
    filter!(rel -> !_ship_unshippable(joinpath(root, rel)), out)
    declared = _load_ship_inputs(root)
    if !isempty(declared)
        filter!(out) do rel
            return !_ship_input_covers(rel, declared)
        end
    end
    sort!(out)
    isempty(out) && throw(ArgumentError("nothing to ship from $root"))
    return out
end

function _ship_rel_paths(ship_root::AbstractString)::Vector{String}
    root = canonical_local_path(ship_root)
    send_list = _ship_gitignore_send_list(root)
    _warn_excluded_ship_project_files!(root, send_list)
    return _ship_members_from_walk(root, send_list)
end

struct ShipInput
    name::String
    path::String
    hash::Bool
end

function _ship_input_covers(rel::AbstractString, inputs::Vector{ShipInput})::Bool
    for input in inputs
        rel == input.path && return true
        startswith(rel, input.path * "/") && return true
    end
    return false
end

function _canonical_ship_input_path(path::AbstractString)::String
    raw = strip(String(path))
    occursin('\\', raw) &&
        throw(ArgumentError("inputs.toml: path contains a backslash: $(repr(path))"))
    any(iscntrl, raw) &&
        throw(ArgumentError("inputs.toml: path contains a control character: $(repr(path))"))
    startswith(raw, "/") &&
        throw(ArgumentError("inputs.toml: path must stay inside the project: $path"))
    parts = String[]
    for piece in split(raw, '/'; keepempty = false)
        piece == "." && continue
        if piece == ".."
            throw(ArgumentError("inputs.toml: path must stay inside the project: $path"))
        end
        push!(parts, piece)
    end
    isempty(parts) &&
        throw(ArgumentError("inputs.toml: path must stay inside the project: $path"))
    return join(parts, "/")
end

function _load_ship_inputs(root::AbstractString)::Vector{ShipInput}
    file = joinpath(root, ".distsshkit", "inputs.toml")
    isfile(file) || return ShipInput[]
    raw = TOML.parsefile(file)
    rows = get(raw, "inputs", Any[])
    rows isa AbstractVector || throw(ArgumentError("inputs.toml: inputs must be an array"))
    out = ShipInput[]
    for row in rows
        row isa AbstractDict || throw(ArgumentError("inputs.toml: each input must be a table"))
        name = strip(string(get(row, "name", "")))
        shown = strip(string(get(row, "path", "")))
        isempty(name) && throw(ArgumentError("inputs.toml: name is required"))
        isempty(shown) && throw(ArgumentError("inputs.toml: path is required for $name"))
        path = _canonical_ship_input_path(shown)
        flag = get(row, "hash", true)
        flag isa Bool || throw(ArgumentError("inputs.toml: hash must be true or false for $name"))
        push!(out, ShipInput(name, path, flag))
    end
    return out
end

const _INPUT_PROBE_EXPR = """
using SHA
function _probe_main()
path = ARGS[1]
do_hash = ARGS[2] == "1"
function fail(msg)
    println(msg)
    exit(2)
end
function lstat_pair(p)
    local st
    try
        st = lstat(p)
    catch
        exit(1)
    end
    return (Int(st.size), trunc(Int, st.mtime))
end
function sha256_hex(feed)
    ctx = SHA.SHA256_CTX()
    buf = Vector{UInt8}(undef, 65536)
    while true
        n = feed(buf)
        n == 0 && break
        SHA.update!(ctx, view(buf, 1:n))
    end
    return bytes2hex(SHA.digest!(ctx))
end
function sha256_bytes(s)
    src = Vector{UInt8}(codeunits(s))
    pos = Ref(1)
    return sha256_hex() do buf
        pos[] > length(src) && return 0
        n = min(length(buf), length(src) - pos[] + 1)
        copyto!(buf, 1, src, pos[], n)
        pos[] += n
        return n
    end
end
function sha256_file(p)
    open(p, "r") do io
        return sha256_hex(buf -> readbytes!(io, buf))
    end
end
function link_target(p)
    sz, _ = lstat_pair(p)
    target = readlink(p)
    stripped = target
    while endswith(stripped, "\n")
        stripped = chop(stripped)
    end
    if sizeof(stripped) != sz || occursin("\n", stripped) || occursin("\t", stripped)
        fail("input link target contains a newline")
    end
    return stripped
end
function c_lt(a, b)
    ca = codeunits(a)
    cb = codeunits(b)
    n = min(length(ca), length(cb))
    for i in 1:n
        ca[i] == cb[i] && continue
        return ca[i] < cb[i]
    end
    return length(ca) < length(cb)
end
function collect(dir, prefix, out)
    for name in readdir(dir)
        occursin("\n", name) && fail("input filename contains a newline")
        rel = isempty(prefix) ? name : prefix * "/" * name
        full = joinpath(dir, name)
        if islink(full)
            push!(out, rel)
        elseif isdir(full)
            collect(full, rel, out)
        elseif isfile(full)
            push!(out, rel)
        end
    end
    return out
end
if !ispath(path) && !islink(path)
    fail("missing")
end
root_target = islink(path) ? link_target(path) : nothing
if isdir(path)
    rels = String[]
    collect(path, "", rels)
    sort!(rels, lt = c_lt)
    if do_hash
        total = 0
        for rel in rels
            full = joinpath(path, rel)
            islink(full) && continue
            sz, _ = lstat_pair(full)
            total += sz
        end
        done = 0
        for rel in rels
            full = joinpath(path, rel)
            if islink(full)
                println("link\\t", link_target(full), "\\t", rel)
            else
                sz, _ = lstat_pair(full)
                hex = sha256_file(full)
                done += sz
                println("file\\t", sz, "\\t", hex, "\\t", rel)
                println(stderr, "PROG ", done, " ", total)
            end
        end
    else
        files = 0
        bytes = 0
        newest = 0
        rows = IOBuffer()
        for rel in rels
            full = joinpath(path, rel)
            sz, mt = lstat_pair(full)
            if islink(full)
                println(rows, rel, "\\tlink\\t", sz, "\\t", mt, "\\t", link_target(full))
            else
                files += 1
                bytes += sz
                println(rows, rel, "\\tfile\\t", sz, "\\t", mt)
            end
            mt > newest && (newest = mt)
        end
        hex = sha256_bytes(String(take!(rows)))
        println("files=", files, " bytes=", bytes, " newest=", newest, " digest=", hex)
    end
elseif isfile(path)
    if do_hash && islink(path)
        println("link\\t", root_target, "\\t.")
    elseif do_hash
        sz, _ = lstat_pair(path)
        hex = sha256_file(path)
        println(stderr, "PROG ", sz, " ", sz)
        println("file\\t", sz, "\\t", hex, "\\t.")
    else
        sz, mt = lstat_pair(path)
        hex = sha256_bytes(".\\tfile\\t" * string(sz) * "\\t" * string(mt) * "\\n")
        println("files=1 bytes=", sz, " newest=", mt, " digest=", hex)
    end
else
    fail("not a file or directory")
end
end
_probe_main()
"""

function _remote_input_probe_sh(
        abs_path::AbstractString,
        do_hash::Bool;
        julia_bin::AbstractString = joinpath(Sys.BINDIR, Base.julia_exename()),
    )::String
    return _remote_stdlib_julia_e(
        julia_bin,
        _INPUT_PROBE_EXPR;
        args = String[_remote_shell_path_word(abs_path), do_hash ? "1" : "0"],
    )
end


const _INPUT_MANIFEST_LOCK = ReentrantLock()

function _format_bytes(n::Integer)::String
    n < 1024 && return string(n, " B")
    x = Float64(n)
    unit = "KB"
    x /= 1024
    if x >= 1024
        x /= 1024
        unit = "MB"
    end
    if x >= 1024
        x /= 1024
        unit = "GB"
    end
    if x >= 1024
        x /= 1024
        unit = "TB"
    end
    return string(round(x; digits = 1), " ", unit)
end

function _format_seconds(t::Real)::String
    secs = max(0.0, Float64(t))
    secs >= 10 && return string(round(Int, secs), " s")
    return string(round(secs; digits = 1), " s")
end

function _input_summary_line(name::AbstractString, nbytes::Integer, elapsed::Real, stat::Bool)::String
    extra = stat ? " (stat)" : ""
    return "hashed $name: $(_format_bytes(nbytes)) in $(_format_seconds(elapsed))$extra"
end

"""Manifest path for one `(name, host)` pair.

The file name is the SHA-256 of `ncodeunits(name):name\\nhost`, so
`(a--b, c)` and `(a, b--c)` do not share a path.
"""
function _input_manifest_rel(name::AbstractString, host::AbstractString)::String
    pair = string(ncodeunits(String(name)), ':', name, '\n', host)
    return "inputs/" * _sha256_hex(codeunits(pair)) * ".manifest"
end

"""`inputs/records.toml` rows, or `nothing` when this run has no declared inputs."""
function _read_declared_input_rows(run_dir::AbstractString)
    file = joinpath(run_dir, "inputs", "records.toml")
    isfile(file) || return nothing
    raw = try
        TOML.parsefile(file)
    catch
        return nothing
    end
    raw isa AbstractDict || return nothing
    rows = get(raw, "inputs", nothing)
    return rows isa AbstractVector ? rows : nothing
end

function _store_input_rows!(run_dir::AbstractString, rows::AbstractVector{<:AbstractDict})
    lock(_INPUT_MANIFEST_LOCK) do
        dir = joinpath(run_dir, "inputs")
        mkpath(dir)
        dest = joinpath(dir, "records.toml")
        existing = if isfile(dest)
            parsed = TOML.parsefile(dest)
            parsed isa AbstractDict ? get(parsed, "inputs", Any[]) : Any[]
        else
            Any[]
        end
        existing isa AbstractVector || (existing = Any[])
        for row in rows
            stored = Dict{String, Any}(String(k) => v for (k, v) in pairs(row))
            name = get(stored, "name", nothing)
            host = get(stored, "host", nothing)
            filter!(
                old -> !(
                    old isa AbstractDict &&
                        get(old, "name", nothing) == name &&
                        get(old, "host", nothing) == host
                ),
                existing,
            )
            push!(existing, stored)
        end
        data = Dict{String, Any}("schema" => 1, "inputs" => existing)
        tmp = dest * ".tmp"
        open(tmp, "w") do io
            TOML.print(io, data)
        end
        mv(tmp, dest; force = true)
    end
    return nothing
end

function _merge_inputs_into_run_toml!(run_dir::AbstractString)
    raw = read_kit_run_toml(run_dir)
    raw === nothing && return nothing
    _kit_run_toml_owned(raw) || return nothing
    rows = _read_declared_input_rows(run_dir)
    rows === nothing && return nothing
    data = Dict{String, Any}(String(k) => v for (k, v) in raw)
    data["inputs"] = rows
    dest = kit_run_toml_path(canonical_local_path(run_dir))
    tmp = dest * ".tmp"
    open(tmp, "w") do io
        TOML.print(io, data)
    end
    mv(tmp, dest; force = true)
    return nothing
end

"""Append `rows` and copy them into `run.toml`. One lock covers both files."""
function _commit_declared_input_rows!(
        run_dir::AbstractString,
        rows::AbstractVector{<:AbstractDict},
    )
    lock(_INPUT_MANIFEST_LOCK) do
        _store_input_rows!(run_dir, rows)
        _merge_inputs_into_run_toml!(run_dir)
    end
    return nothing
end

function _nfc_input_rel(rel::AbstractString)::String
    raw = String(rel)
    occursin('\\', raw) && throw(ArgumentError("input path contains a backslash"))
    raw = Unicode.normalize(raw, :NFC)
    any(iscntrl, raw) && throw(ArgumentError("input path contains a control character"))
    parts = String[]
    for piece in split(raw, '/'; keepempty = false)
        piece == "." && continue
        piece == ".." && throw(ArgumentError("input path escapes the declared root"))
        push!(parts, piece)
    end
    return isempty(parts) ? "." : join(parts, "/")
end

function _manifest_line(hex::AbstractString, path::AbstractString)::String
    occursin('\n', path) && throw(ArgumentError("input path contains a newline"))
    return lowercase(String(hex)) * " *" * path
end

function _input_manifest_entry(line::AbstractString)::Tuple{String, String}
    m = match(r"^([0-9a-fA-F]{64}) \*(.*)$", line)
    m === nothing && throw(ArgumentError("input manifest line is not sha256sum form: $(repr(line))"))
    rel = _nfc_input_rel(_regex_field(m, 2))
    rel == "." && throw(ArgumentError("input manifest path is empty"))
    return lowercase(_regex_field(m, 1)), rel
end

"""Resolve `rel` under `root` by matching each path component as NFC.

The manifest stores NFC names. A filesystem that keeps NFD still verifies.
"""
function _resolve_nfc_under(root::AbstractString, rel::AbstractString)
    current = String(root)
    for piece in split(rel, '/'; keepempty = false)
        piece == "." && continue
        piece == ".." && throw(ArgumentError("input path escapes the declared root"))
        literal = joinpath(current, piece)
        if ispath(literal) || islink(literal)
            current = literal
            continue
        end
        isdir(current) || return nothing
        found = nothing
        for name in readdir(current; join = false)
            if Unicode.normalize(String(name), :NFC) == piece
                found = String(name)
                break
            end
        end
        found === nothing && return nothing
        current = joinpath(current, found)
    end
    return current
end

"""Check `manifest` against `root`.

A regular file is the SHA-256 of its bytes. A symlink is the SHA-256 of
its link text and is not followed. `sha256sum -c` follows a symlink and
normally reports `FAILED`, and it opens paths literally so it can miss
an NFD directory entry that matches an NFC manifest path. Use this
function to verify both.
"""
function check_input_manifest(manifest::AbstractString, root::AbstractString)
    for raw in eachsplit(read(manifest, String), '\n'; keepempty = false)
        hex, rel = _input_manifest_entry(String(raw))
        full = _resolve_nfc_under(root, rel)
        full === nothing && throw(ArgumentError("input manifest path is missing: $rel"))
        got = if islink(full)
            _sha256_hex(codeunits(readlink(full)))
        elseif isfile(full)
            _sha256_file(full)
        else
            throw(ArgumentError("input manifest path is missing: $rel"))
        end
        got == hex || throw(ArgumentError("input manifest mismatch: $rel"))
    end
    return nothing
end

function _regex_field(m::RegexMatch, i::Int)::String
    cap = m.captures[i]
    cap isa AbstractString || throw(ArgumentError("regex capture $i was empty"))
    return String(cap)
end

function _input_row_from_probe(
        name::AbstractString,
        path::AbstractString,
        host::AbstractString,
        do_hash::Bool,
        output::AbstractString,
        run_dir::AbstractString,
    )::Dict{String, Any}
    hashed_at = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS") * "Z"
    if !do_hash
        m = match(r"^files=(\d+) bytes=(\d+) newest=(\d+) digest=([0-9a-fA-F]{64})$", strip(output))
        m === nothing && throw(ArgumentError("input $name: stat fingerprint was not a single line"))
        return Dict{String, Any}(
            "name" => String(name),
            "path" => String(path),
            "host" => String(host),
            "algorithm" => "stat",
            "files" => parse(Int, _regex_field(m, 1)),
            "bytes" => parse(Int, _regex_field(m, 2)),
            "newest_mtime" => parse(Int, _regex_field(m, 3)),
            "stat_digest" => lowercase(_regex_field(m, 4)),
            "verification" => "stat",
            "hashed_at" => hashed_at,
        )
    end
    entries = Tuple{String, String, Int, Bool}[]
    for raw in eachsplit(output, '\n'; keepempty = false)
        line = String(raw)
        parts = split(line, '\t')
        kind = parts[1]
        if kind == "file"
            length(parts) == 4 || throw(ArgumentError("input $name: bad file record"))
            sz = tryparse(Int, String(parts[2]))
            sz === nothing && throw(ArgumentError("input $name: bad file size"))
            hex = String(parts[3])
            occursin(r"^[0-9a-fA-F]{64}$", hex) || throw(ArgumentError("input $name: bad sha256"))
            rel = _nfc_input_rel(String(parts[4]))
            if rel == "."
                rel = _nfc_input_rel(basename(String(path)))
                rel == "." && throw(ArgumentError("input $name: file record has no name"))
            end
            push!(entries, (rel, lowercase(hex), sz, false))
        elseif kind == "link"
            length(parts) == 3 || throw(ArgumentError("input $name: bad link record"))
            target = String(parts[2])
            hex = _sha256_hex(codeunits(target))
            rel = _nfc_input_rel(String(parts[3]))
            if rel == "."
                rel = _nfc_input_rel(basename(String(path)))
                rel == "." && throw(ArgumentError("input $name: link record has no name"))
            end
            push!(entries, (rel, hex, 0, true))
        else
            throw(ArgumentError("input $name: unknown record $(repr(kind))"))
        end
    end
    sort!(entries; by = first)
    seen = Set{String}()
    io = IOBuffer()
    nbytes = 0
    nfiles = 0
    for (rel, hex, sz, islink) in entries
        rel in seen && throw(ArgumentError("input $name: duplicate path $rel"))
        push!(seen, rel)
        println(io, _manifest_line(hex, rel))
        islink && continue
        nbytes += sz
        nfiles += 1
    end
    body = take!(io)
    relmanifest = _input_manifest_rel(name, host)
    dest = joinpath(run_dir, relmanifest)
    mkpath(dirname(dest))
    tmp = dest * ".tmp"
    open(tmp, "w") do file
        write(file, body)
    end
    mv(tmp, dest; force = true)
    return Dict{String, Any}(
        "name" => String(name),
        "path" => String(path),
        "host" => String(host),
        "algorithm" => "sha256-manifest-v1",
        "content_hash" => _sha256_hex(body),
        "files" => nfiles,
        "bytes" => nbytes,
        "verification" => "sha256",
        "hashed_at" => hashed_at,
        "manifest" => relmanifest,
    )
end

function _show_input_progress!(name::AbstractString, line::AbstractString, t0::Float64, last_pct::Ref{Int})
    m = match(r"^PROG (\d+) (\d+)$", line)
    m === nothing && return nothing
    done = tryparse(Int, _regex_field(m, 1))
    total = tryparse(Int, _regex_field(m, 2))
    (done === nothing || total === nothing) && return nothing
    total <= 0 && return nothing
    pct = min(100, fld(100 * done, total))
    pct == 100 && return nothing
    pct < last_pct[] + 10 && return nothing
    last_pct[] = pct
    elapsed = time() - t0
    rate = elapsed > 0 ? done / elapsed : 0.0
    eta = rate > 0 ? (total - done) / rate : 0.0
    kit_println(
        "hashed $name: $(_format_bytes(done)) / $(_format_bytes(total)), $(_format_seconds(eta)) left",
    )
    return nothing
end

function _remote_script_output(
        on_line::Function,
        host::AbstractString,
        script::AbstractString,
    )::Tuple{Int, String, String}
    _ensure_posix_login_shell!(String(host))
    out_pipe = Pipe()
    err_pipe = Pipe()
    cmd = _host_sync_remote_shell_cmd(String(host), script)
    proc = try
        run(pipeline(ignorestatus(cmd); stdout = out_pipe, stderr = err_pipe); wait = false)
    catch e
        _rethrow_missing_host_tool(e)
        rethrow()
    end
    close(out_pipe.in)
    close(err_pipe.in)
    out_task = @async String(read(out_pipe))
    err_task = @async begin
        text = IOBuffer()
        for line in eachline(err_pipe)
            println(text, line)
            on_line(String(line))
        end
        String(take!(text))
    end
    wait(proc)
    out = fetch(out_task)
    err = fetch(err_task)
    code = DistSSHBase.shell_status(proc)
    if code == 255
        throw(
            ArgumentError(
                summarize_ssh_error(
                    Base.ProcessFailedException(Base.Process[proc]);
                    stderr = err,
                ),
            ),
        )
    end
    code == 0 || _throw_if_nonposix_shell(String(host), code, err)
    return code, out, err
end

const _PENDING_INPUT_HASH_LOCK = ReentrantLock()
const _PENDING_INPUT_HASH_TASKS = Task[]

function _record_remote_inputs!(
        host::AbstractString,
        abs_root::AbstractString,
        local_root::AbstractString,
        julia_bin::AbstractString,
    )
    inputs = _load_ship_inputs(local_root)
    isempty(inputs) && return nothing
    run_dir = kit_run_dir()
    run_dir === nothing && throw(
        ArgumentError(
            "ship-tree: declared inputs need DISTSSHKIT_RUN_DIR; refusing to write next to the project",
        ),
    )
    rows = Dict{String, Any}[]
    for input in inputs
        remote = _posix_join(abs_root, input.path)
        t0 = time()
        last_pct = Ref(-1)
        code, out, err = _remote_script_output(
            String(host),
            _remote_input_probe_sh(remote, input.hash; julia_bin = julia_bin),
        ) do line
            input.hash && _show_input_progress!(input.name, line, t0, last_pct)
            return nothing
        end
        elapsed = time() - t0
        code == 0 || throw(
            ArgumentError("$(host): input $(input.name) ($(remote)): $(strip(err * out))"),
        )
        row = _input_row_from_probe(
            input.name, input.path, host, input.hash, out, run_dir,
        )
        push!(rows, row)
        kit_println(_input_summary_line(input.name, Int(row["bytes"]), elapsed, !input.hash))
    end
    _commit_declared_input_rows!(run_dir, rows)
    return nothing
end

"""Start remote input hashing for `host` without waiting. See [`await_declared_input_hashes!`](@ref)."""
function _start_remote_input_hashes!(
        host::AbstractString,
        abs_root::AbstractString,
        local_root::AbstractString,
        julia_bin::AbstractString,
    )
    inputs = _load_ship_inputs(local_root)
    isempty(inputs) && return nothing
    kit_run_dir() === nothing && throw(
        ArgumentError(
            "ship-tree: declared inputs need DISTSSHKIT_RUN_DIR; refusing to write next to the project",
        ),
    )
    task = @async _record_remote_inputs!(host, abs_root, local_root, julia_bin)
    lock(_PENDING_INPUT_HASH_LOCK) do
        push!(_PENDING_INPUT_HASH_TASKS, task)
    end
    return nothing
end

"""Wait for deferred declared-input hashes from ship (`await_inputs=false`).

An interrupt during `fetch` leaves that hash task in the drain set until it
finishes. The interrupt is rethrown after every pending hash completes, and
it is not hidden by an earlier task failure.
"""
function await_declared_input_hashes!()
    tasks = lock(_PENDING_INPUT_HASH_LOCK) do
        taken = copy(_PENDING_INPUT_HASH_TASKS)
        empty!(_PENDING_INPUT_HASH_TASKS)
        return taken
    end
    first_err = nothing
    interrupt_err = nothing
    i = 1
    while i <= length(tasks)
        task = tasks[i]
        try
            fetch(task)
            i += 1
        catch e
            if e isa InterruptException ||
                    (isdefined(Base, :CancellationRequest) && e isa Base.CancellationRequest)
                interrupt_err = e
            else
                first_err === nothing && (first_err = e)
                i += 1
            end
        end
    end
    interrupt_err === nothing || throw(interrupt_err)
    first_err === nothing || throw(first_err)
    return nothing
end

function _lexical_join(base::AbstractString, target::AbstractString)::Vector{String}
    parts = String[]
    if startswith(target, '/')
        return String[p for p in split(target, '/'; keepempty = false)]
    end
    append!(parts, split(replace(String(base), '\\' => '/'), '/'; keepempty = false))
    for p in split(replace(String(target), '\\' => '/'), '/'; keepempty = false)
        p == "." && continue
        if p == ".."
            isempty(parts) || pop!(parts)
            continue
        end
        push!(parts, p)
    end
    return parts
end

function _symlink_escapes_root(
        root::AbstractString,
        rel::AbstractString,
        target::AbstractString,
    )::Bool
    startswith(target, '/') && return true
    root_parts = split(replace(canonical_local_path(root), '\\' => '/'), '/'; keepempty = false)
    from = joinpath(root, dirname(rel))
    joined = _lexical_join(from, target)
    length(joined) < length(root_parts) && return true
    for (a, b) in zip(root_parts, joined)
        a == b || return true
    end
    return false
end

function _check_ship_symlinks!(
        root::AbstractString,
        rels::Vector{String};
        allow_external::Bool,
    )::Vector{String}
    recorded = String[]
    for rel in rels
        p = joinpath(root, rel)
        islink(p) || continue
        target = readlink(p)
        if _symlink_escapes_root(root, rel, target)
            allow_external || throw(
                ArgumentError(
                    "escaping symlink $(repr(rel)) -> $(repr(target)); pass --allow-external-symlinks",
                ),
            )
            push!(recorded, string(rel, " -> ", target))
        end
        dest = isabspath(target) ? target : joinpath(dirname(p), target)
        if !isdir(dest) && !isfile(dest) && !islink(dest)
            @warn "ship-tree: dangling symlink $rel -> $target"
        end
    end
    return recorded
end

"""Non-negative byte limit from `name`, or `default` when unset. Read at pack time."""
function _ship_warn_limit(name::AbstractString, default::Integer)::Int
    raw = get(ENV, name, nothing)
    raw === nothing && return Int(default)
    n = tryparse(Int, strip(raw))
    if n === nothing || n < 0
        throw(ArgumentError("$name must be a non-negative integer, got $(repr(raw))"))
    end
    return n
end

function _ship_dir_bytes(sizes::Vector{Tuple{Int, String}})::Vector{Pair{String, Int}}
    acc = Dict{String, Int}()
    for (sz, rel) in sizes
        parts = split(rel, '/')
        length(parts) < 2 && continue
        prefix = ""
        for part in parts[1:(end - 1)]
            prefix = isempty(prefix) ? String(part) : string(prefix, "/", part)
            acc[prefix] = get(acc, prefix, 0) + sz
        end
    end
    listed = collect(acc)
    sort!(listed; by = last, rev = true)
    return listed
end

function _warn_ship_list_size!(total::Integer, sizes::Vector{Tuple{Int, String}}, limit::Integer)
    total > limit || return nothing
    sort!(sizes; by = first, rev = true)
    n = min(10, length(sizes))
    files = join((string(rel, " (", sz, ")") for (sz, rel) in sizes[1:n]), "\n  ")
    dirs = _ship_dir_bytes(sizes)
    nd = min(10, length(dirs))
    dir_lines = nd == 0 ? "" : join((string(rel, " (", sz, ")") for (rel, sz) in dirs[1:nd]), "\n  ")
    msg = "Warning: ship-tree send list is $total bytes (> $limit). Largest files:\n  $files\n"
    if !isempty(dir_lines)
        msg *= "Largest directories:\n  $dir_lines\n"
    end
    print_warn(msg)
    return nothing
end

function _ship_bytes_and_files(root::AbstractString, rels::Vector{String})
    file_limit = _ship_warn_limit(_SHIP_WARN_FILE_ENV, SHIP_FILE_WARN_BYTES)
    total_limit = _ship_warn_limit(_SHIP_WARN_TOTAL_ENV, SHIP_WARN_TOTAL_BYTES_DEFAULT)
    total = 0
    nfiles = 0
    sizes = Tuple{Int, String}[]
    for rel in rels
        p = joinpath(root, rel)
        isfile(p) && !islink(p) || continue
        sz = Int(filesize(p))
        total += sz
        nfiles += 1
        push!(sizes, (sz, rel))
        sz > file_limit && @warn "ship-tree: $rel is $(sz) bytes (> $file_limit bytes)"
    end
    _warn_ship_list_size!(total, sizes, total_limit)
    return total, nfiles, sizes
end

function _ship_keep(want::Set{String}, root::AbstractString, path::AbstractString)::Bool
    r = replace(relpath(String(path), root), '\\' => '/')
    (isempty(r) || r == ".") && return true
    r in want && return true
    any(startswith(w, r * "/") for w in want) && return true
    return false
end

function pack_ship_tar(
        local_root::AbstractString;
        allow_external_symlinks::Bool = false,
        ship_max_bytes::Integer = SHIP_MAX_BYTES_DEFAULT,
    )
    local_dir = canonical_local_path(local_root)
    root = _ship_tree_root(local_dir)
    _warn_ship_outside!(local_dir, root)
    rels = _ship_rel_paths(root)
    allowed_links = _check_ship_symlinks!(
        root, rels; allow_external = allow_external_symlinks,
    )
    total, nfiles, sizes = _ship_bytes_and_files(root, rels)
    if total > Int(ship_max_bytes)
        sort!(sizes; by = first, rev = true)
        top = join(
            (string(rel, " (", sz, ")") for (sz, rel) in sizes[1:min(10, length(sizes))]),
            "\n  ",
        )
        throw(
            ArgumentError(
                "ship-tree: tree is $total bytes (cap $(Int(ship_max_bytes))). Largest:\n  $top\n.gitignore them or declare data directories (0.3.0).",
            ),
        )
    end
    want = Set{String}(rels)
    tmpd = mktempdir()
    tar_path = joinpath(tmpd, "ship.tar")
    try
        Tar.create(p -> _ship_keep(want, root, p), root, tar_path)
        hash = Tar.tree_hash(tar_path; algorithm = "git-sha1", skip_empty = true)
        return (
            tar_path = tar_path,
            tmpd = tmpd,
            hash = String(hash),
            bytes = total,
            files = nfiles,
            tree_matches_head = nothing,
            external_symlinks = allowed_links,
            root = root,
        )
    catch
        rm(tmpd; force = true, recursive = true)
        rethrow()
    end
end

"""
    snapshot(local_root; allow_external_symlinks=false, ship_max_bytes=SHIP_MAX_BYTES_DEFAULT) -> ShipSnapshot

Build the ship tar in a temporary directory and record its `content_tree_hash`.

The caller owns [`snapshot_directory`](@ref) and deletes it, including the
[`snapshot_tar`](@ref) file (`ship.tar`). This does not read depot
preferences and does not send anything.
"""
function snapshot(
        local_root::AbstractString;
        allow_external_symlinks::Bool = false,
        ship_max_bytes::Integer = SHIP_MAX_BYTES_DEFAULT,
    )::ShipSnapshot
    packed = pack_ship_tar(
        local_root;
        allow_external_symlinks = allow_external_symlinks,
        ship_max_bytes = ship_max_bytes,
    )
    return ShipSnapshot(
        packed.tmpd,
        packed.tar_path,
        packed.hash,
        packed.bytes,
        packed.files,
        packed.tree_matches_head,
        allow_external_symlinks,
        packed.root,
        String(local_root),
    )
end
public snapshot

"""Temporary directory that holds a [`ShipSnapshot`](@ref) tar. The caller deletes it."""
function snapshot_directory(snapshot::ShipSnapshot)::String
    return snapshot.directory
end
public snapshot_directory

"""`ship.tar` inside [`snapshot_directory`](@ref)."""
function snapshot_tar(snapshot::ShipSnapshot)::String
    return snapshot.tar_path
end
public snapshot_tar

"""`git-sha1` tree hash recorded by [`snapshot`](@ref)."""
function content_tree_hash(snapshot::ShipSnapshot)::String
    return snapshot.content_tree_hash
end
public content_tree_hash

function _ship_tar_tree_hash(tar_path::AbstractString)::String
    return String(Tar.tree_hash(tar_path; algorithm = "git-sha1", skip_empty = true))
end

"""Throw `ArgumentError` when the tar bytes no longer match the recorded hash."""
function _require_snapshot_unchanged!(snapshot::ShipSnapshot)
    tar_path = snapshot.tar_path
    isfile(tar_path) || throw(ArgumentError("ship: snapshot tar is missing"))
    got = _ship_tar_tree_hash(tar_path)
    got == snapshot.content_tree_hash || throw(
        ArgumentError(
            "ship: tar content_tree_hash $(got) does not match snapshot $(snapshot.content_tree_hash)",
        ),
    )
    return nothing
end

const _PROJECT_PREFERENCE_NAMES = ("LocalPreferences.toml", "JuliaLocalPreferences.toml")

function _depot_preference_paths()::Vector{String}
    paths = String[]
    isempty(Base.DEPOT_PATH) && return paths
    depot = String(first(Base.DEPOT_PATH))
    ov = joinpath(depot, "artifacts", "Overrides.toml")
    isfile(ov) && push!(paths, ov)
    env = joinpath(depot, "environments", "v$(VERSION.major).$(VERSION.minor)")
    for name in _PROJECT_PREFERENCE_NAMES
        p = joinpath(env, name)
        isfile(p) && push!(paths, p)
    end
    return paths
end

function _preference_toml_affects(path::AbstractString)::Bool
    raw = try
        TOML.parsefile(path)
    catch
        return true
    end
    return raw isa AbstractDict && !isempty(raw)
end

"""Refuse when a depot override or `@v#.#` preference would apply and is not in the ship."""
function _refuse_unshipped_depot_prefs!(paths::AbstractVector{<:AbstractString} = _depot_preference_paths())
    hits = String[]
    for path in paths
        isfile(path) || continue
        _preference_toml_affects(path) || continue
        digest = _sha256_hex(read(path))
        push!(hits, string(path, " sha256=", digest))
    end
    isempty(hits) && return nothing
    throw(
        ArgumentError(
            "ship-tree: depot preferences affect this job and are not shipped:\n  " *
                join(hits, "\n  "),
        ),
    )
end

"""Remote login home. `physical=true` uses `cd -P ~ && pwd -P`."""
function _remote_home(host::AbstractString; physical::Bool = true)::String
    script = physical ? "cd -P ~ && pwd -P" : "cd ~ && pwd"
    code, home_out = _remote_shell_status(String(host), script)
    code == 0 || throw(ArgumentError("could not resolve \$HOME on $(host)"))
    home = strip(home_out)
    isempty(home) && throw(ArgumentError("could not resolve \$HOME on $(host)"))
    return home
end

"""Expand `remote_root` to an absolute path on `host` (tilde may stay logical)."""
function _expand_remote_root_abs(host::AbstractString, remote_root::AbstractString)::String
    path = strip(String(remote_root))
    abs_root = if startswith(path, "/")
        path
    else
        code, out = _remote_shell_status(
            String(host),
            DistSSHBase._remote_abs_path_resolve_shell(path),
        )
        code == 0 || throw(
            ArgumentError("could not resolve remote_root on $(host): $remote_root"),
        )
        strip(out)
    end
    isempty(abs_root) && throw(
        ArgumentError("could not resolve remote_root on $(host): $remote_root"),
    )
    return String(abs_root)
end

"""
Rewrite a login-home path onto the physical home used by under-home ensure.

`~/…` expansion and `cd ~ && pwd` are often logical when \$HOME is a symlink,
while under-home creation keys off `cd -P ~ && pwd -P`. Paths already under
`physical_home` are returned unchanged.
"""
function _rehome_logical_under_physical_home(
        abs_root::AbstractString,
        logical_home::AbstractString,
        physical_home::AbstractString,
    )::String
    al = rstrip(String(abs_root), '/')
    lh = rstrip(String(logical_home), '/')
    ph = rstrip(String(physical_home), '/')
    isempty(al) && throw(ArgumentError("remote_root is empty"))
    isempty(lh) && throw(ArgumentError("remote \$HOME is empty"))
    isempty(ph) && throw(ArgumentError("remote \$HOME is empty"))
    al == lh && throw(ArgumentError("remote_root must not be \$HOME"))
    al == ph && throw(ArgumentError("remote_root must not be \$HOME"))
    if startswith(al, lh * "/")
        return ph * al[(ncodeunits(lh) + 1):end]
    elseif startswith(al, ph * "/")
        return al
    end
    throw(
        ArgumentError(
            "remote_root $(repr(al)) is not under remote home $(repr(ph))",
        ),
    )
end

function _probe_expanded_remote_root(host::AbstractString, remote_root::AbstractString)::String
    abs_root = _expand_remote_root_abs(host, remote_root)
    home = _remote_home(host; physical = true)
    return validate_expanded_remote_root(String(abs_root), String(home))
end

"""Deprecated probe kept for fixtures that still emit `__DSR_SHIP_SRC__`.

Selection no longer uses lexical latest `runs/*/src`. Prefer
[`resolve_snapshot_selection`](@ref).
"""
function _remote_project_work_root(host::AbstractString, remote_root::AbstractString)::String
    given = strip(String(remote_root))
    isempty(given) && return given
    abs_root = try
        _probe_expanded_remote_root(host, given)
    catch
        given
    end
    rq = _remote_shell_path_word(abs_root)
    script = """
    # __DSR_SHIP_SRC__
    if test -f $rq/Project.toml || test -f $rq/JuliaProject.toml; then
      printf '%s\\n' $rq
      exit 0
    fi
    printf '%s\\n' $rq
    exit 0
    """
    code, out = _remote_shell_status(String(host), script)
    code == 0 || return given
    s = strip(out)
    return isempty(s) ? given : s
end

function _last_ship_src_for(
        hosts::AbstractVector{<:AbstractString},
        remote_root::AbstractString,
    )::Union{Nothing, String}
    src = _shipped_src()
    src === nothing && return nothing
    rec = last_ship_result()
    rec === nothing && return nothing
    shipped = get(rec, "hosts", nothing)
    shipped isa AbstractVector || return nothing
    have = Set{String}(String(h) for h in shipped)
    all(h -> String(h) in have, hosts) || return nothing
    stored = get(rec, "remote_root", nothing)
    stored isa AbstractString || return nothing
    _deploy_roots_equivalent(stored, remote_root) || return nothing
    return src
end

"""Resolve the remote work root via explicit snapshot, local record, or git."""
function _work_root_for_hosts(
        hosts::AbstractVector{<:AbstractString},
        remote_root::AbstractString;
        local_project::Union{Nothing, AbstractString} = nothing,
        snapshot::Union{Nothing, AbstractString} = nothing,
    )::String
    isempty(hosts) && return String(remote_root)
    proj = local_project === nothing ? pwd() : String(local_project)
    sel = resolve_snapshot_selection(
        hosts, remote_root, proj; snapshot = snapshot,
    )
    _set_active_selection!(sel)
    return sel.work_root
end

"""Worker `--project` after selection: snapshot `src` or git deploy root, plus member rel.

Matches `remote_deploy_root`, not `session_remote_root`. A workspace member is
then joined onto that work root. Pass `snapshot=` for an explicit ID.
"""
function _project_work_root(
        hosts::AbstractVector{<:AbstractString},
        local_project::AbstractString;
        cli_override::Union{Nothing, AbstractString} = nothing,
        snapshot::Union{Nothing, AbstractString} = nothing,
    )::String
    deploy = remote_deploy_root(local_project; cli_override = cli_override)
    mapped = resolve_remote_project_root(local_project; cli_override = cli_override)
    wr = _work_root_for_hosts(
        hosts, deploy;
        local_project = local_project, snapshot = snapshot,
    )
    return _rehome_under_work_root(mapped, deploy, wr)
end

"""Point `DISTRIBUTED_REMOTE_PROJECT_ROOT` at [`_project_work_root`](@ref).

No hosts leaves the env alone. `cli_override=nothing` reads the current env.
A control character in that override or in the resolved root leaves the env alone.
Shared by `drive` (no pre-run sync) and `ride` (SSH children).
"""
function _assign_remote_work_root_env!(
        hosts::AbstractVector{<:AbstractString},
        local_project::AbstractString;
        cli_override::Union{Nothing, AbstractString} = nothing,
        snapshot::Union{Nothing, AbstractString} = nothing,
    )::Nothing
    isempty(hosts) && return nothing
    cli = if cli_override === nothing
        env_rr = strip(get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", ""))
        isempty(env_rr) ? nothing : env_rr
    else
        s = strip(String(cli_override))
        isempty(s) ? nothing : s
    end
    if cli === nothing || !any(iscntrl, String(cli))
        wr = _project_work_root(
            hosts, local_project; cli_override = cli, snapshot = snapshot,
        )
        if !any(iscntrl, String(wr))
            ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = remote_env_project_root(wr)
        end
    end
    return nothing
end

"""Rewrite `mapped` from under `deploy` onto `work` (`runs/<id>/src` when that is the project)."""
function _rehome_under_work_root(
        mapped::AbstractString,
        deploy::AbstractString,
        work::AbstractString,
    )::String
    d = rstrip(String(strip(String(deploy))), '/')
    w = rstrip(String(strip(String(work))), '/')
    m = String(mapped)
    (isempty(d) || d == w) && return m
    m == d && return w
    startswith(m, d * "/") || return m
    return w * m[(ncodeunits(d) + 1):end]
end

"""`remote_layout_path` re-homed onto the remote work root for `hosts`.

After [`_assign_remote_work_root_env!`](@ref), `DISTRIBUTED_REMOTE_PROJECT_ROOT`
holds the work root (`runs/<id>/src`), not the deploy root. Mapping must use
the deploy root (via [`active_snapshot_selection`](@ref) or a temporary ENV),
then rehome onto the work root — otherwise `remote_layout_path` already returns
a work-root path and rehome nests `runs/<id>/src/runs/<id>`.

Reuse the active selection only when its deploy root and hosts cover this call
(so a later standalone `collect!` after a ship to another root/host set
re-resolves instead of collecting the wrong tree).
"""
function _remote_work_layout_path(
        local_abs::AbstractString,
        local_repo::AbstractString,
        hosts::AbstractVector{<:AbstractString};
        snapshot::Union{Nothing, AbstractString} = nothing,
    )::String
    sel = active_snapshot_selection()
    deploy = _layout_intended_deploy_root(local_repo, sel)
    reuse = sel !== nothing &&
        _deploy_roots_equivalent(sel.deploy_root, deploy) &&
        _hosts_covered(sel.hosts, hosts) &&
        (
        snapshot === nothing ||
            (
            sel.snapshot_id !== nothing &&
                String(sel.snapshot_id) == String(snapshot)
        )
    )
    if !reuse
        _work_root_for_hosts(
            hosts, deploy;
            local_project = local_repo, snapshot = snapshot,
        )
        sel = active_snapshot_selection()
    end
    sel isa SnapshotSelection || throw(
        ArgumentError(
            "remote work layout: no snapshot selection after resolve for $(hosts)",
        ),
    )
    chosen = sel::SnapshotSelection
    mapped = withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => chosen.deploy_root) do
        remote_layout_path(local_abs, local_repo)
    end
    return _rehome_under_work_root(mapped, chosen.deploy_root, chosen.work_root)
end

"""Shell that refuses a missing, unreadable, group-writable, world-writable, or foreign `remote_root`."""
function _remote_root_mode_sh(rootq::AbstractString)::String
    return """
    if [ ! -d $rootq ]; then
      printf 'remote_root does not exist: %s\\n' $rootq
      exit 2
    fi
    mode=\$(ls -ldL $rootq) || {
      printf 'could not read remote_root mode\\n'
      exit 2
    }
    mode=\$(printf '%s\\n' "\$mode" | awk '{ print \$1; exit }') || {
      printf 'could not read remote_root mode\\n'
      exit 2
    }
    case "\$mode" in
      d????????*) ;;
      *)
        printf 'could not read remote_root mode (%s)\\n' "\$mode"
        exit 2
        ;;
    esac
    gw=\$(printf '%.1s' "\${mode#?????}")
    ow=\$(printf '%.1s' "\${mode#????????}")
    if [ -z "\$gw" ] || [ -z "\$ow" ]; then
      printf 'could not read remote_root mode (%s)\\n' "\$mode"
      exit 2
    fi
    if [ "\$gw" = w ] || [ "\$ow" = w ]; then
      printf 'remote_root is group or world writable (%s)\\n' "\$mode"
      exit 2
    fi
    me=\$(id -un) || exit 1
    owner=\$(stat -L -c '%U' $rootq 2>/dev/null || stat -L -f '%Su' $rootq) || exit 1
    if [ -z "\$owner" ] || [ "\$owner" != "\$me" ]; then
      printf 'remote_root owner is %s, not %s\\n' "\$owner" "\$me"
      exit 2
    fi
    """
end

"""Absolute `remote_root` from an explicit `--remote-path` or `session.remote`.

A `~` path, a relative path, and a path this package will not use as a clone
or delete target are refused. Nothing is read from the environment.
"""
function explicit_remote_root_path(path::AbstractString)::String
    raw = String(path)
    any(c -> c == '\n' || c == '\r' || c == '\0' || iscntrl(c), raw) && throw(
        ArgumentError("remote_root path contains a control character"),
    )
    s = strip(raw)
    startswith(s, "/") || throw(
        ArgumentError(
            "setup --remote-root needs an absolute path; refusing $(repr(s))",
        ),
    )
    return _checked_remote_dest(rstrip(s, '/'))
end

"""Create `abs_path` with mode `700` when it is missing. The parent must already exist.

`chmod go-w` clears group and other write again when a default ACL added it.
A concurrent creator that leaves a safe directory is accepted; an unsafe
replacement is still refused by [`_remote_root_mode_sh`](@ref). Existing
directories are not chmod'd or chown'd. When `report=true`, prints
`CREATED` or `EXISTED` after validation.
"""
function _remote_root_create_script(
        abs_path::AbstractString;
        report::Bool = false,
    )::String
    path = explicit_remote_root_path(abs_path)
    q = _remote_shell_path_word(path)
    parent = dirname(path)
    pq = _remote_shell_path_word(parent)
    report_sh = report ? """
        if [ \"\$__dsr_rr_created\" = 1 ]; then
          printf 'CREATED\\n'
        else
          printf 'EXISTED\\n'
        fi
        """ : ""
    return """
    # __DSR_ENSURE_REMOTE_ROOT__
    __dsr_rr_created=0
    if [ -L $q ]; then
      printf 'remote_root is a symlink: %s\\n' $q
      exit 2
    fi
    if [ -e $q ] && [ ! -d $q ]; then
      printf 'remote_root exists and is not a directory: %s\\n' $q
      exit 2
    fi
    if [ ! -d $q ]; then
      if [ ! -d $pq ]; then
        printf 'remote_root parent does not exist: %s\\n' $pq
        exit 2
      fi
      if mkdir -m 700 $q 2>/dev/null; then
        chmod go-w $q || exit 1
        __dsr_rr_created=1
      else
        if [ -L $q ]; then
          printf 'remote_root is a symlink: %s\\n' $q
          exit 2
        fi
        if [ ! -d $q ]; then
          printf 'remote_root mkdir failed: %s\\n' $q
          exit 1
        fi
      fi
    fi
    $(_remote_root_mode_sh(q))
    $report_sh
    """
end

"""Create missing components of `abs_root` under the remote home with mode `700`.

`abs_root` and `home` are already absolute. Existing ancestor symlinks that
resolve to directories are followed; a symlink at the final target, or at a
component this script creates (including a raced symlink), is refused.
Existing directories are not chmod'd. Prints `CREATED` or `EXISTED`.
"""
function _remote_root_ensure_under_home_script(
        abs_root::AbstractString,
        home::AbstractString,
    )::String
    root = validate_expanded_remote_root(String(abs_root), String(home))
    h = rstrip(String(home), '/')
    isempty(h) && throw(ArgumentError("remote \$HOME is empty"))
    startswith(root, h * "/") || throw(
        ArgumentError(
            "remote_root $(repr(root)) is not under remote home $(repr(h))",
        ),
    )
    rq = _remote_shell_path_word(root)
    hq = _remote_shell_path_word(h)
    return """
    # __DSR_ENSURE_REMOTE_ROOT__
    root=$rq
    home=$hq
    case \"\$root\" in
      \"\$home\"/*) ;;
      *)
        printf 'remote_root is not under home: %s\\n' \"\$root\"
        exit 2
        ;;
    esac
    rel=\${root#\"\$home\"/}
    cur=\"\$home\"
    created=0
    oldifs=\$IFS
    IFS=/
    set -f
    set -- \$rel
    set +f
    IFS=\$oldifs
    for part in \"\$@\"; do
      [ -n \"\$part\" ] || continue
      if [ \"\$part\" = \".\" ] || [ \"\$part\" = \"..\" ]; then
        printf 'remote_root path contains . or ..\\n'
        exit 2
      fi
      next=\"\$cur/\$part\"
      if [ -L \"\$next\" ]; then
        if [ \"\$next\" = \"\$root\" ]; then
          printf 'remote_root is a symlink: %s\\n' \"\$next\"
          exit 2
        fi
        if [ -d \"\$next\" ]; then
          cur=\"\$next\"
          continue
        fi
        printf 'remote_root component is a symlink: %s\\n' \"\$next\"
        exit 2
      fi
      if [ ! -e \"\$next\" ]; then
        if mkdir -m 700 \"\$next\" 2>/dev/null; then
          chmod go-w \"\$next\" || exit 1
          created=1
        else
          if [ -L \"\$next\" ]; then
            printf 'remote_root component is a symlink: %s\\n' \"\$next\"
            exit 2
          fi
          if [ ! -d \"\$next\" ]; then
            printf 'remote_root mkdir failed: %s\\n' \"\$next\"
            exit 1
          fi
        fi
      elif [ ! -d \"\$next\" ]; then
        printf 'remote_root exists and is not a directory: %s\\n' \"\$next\"
        exit 2
      fi
      cur=\"\$next\"
    done
    if [ -L \"\$root\" ]; then
      printf 'remote_root is a symlink: %s\\n' \"\$root\"
      exit 2
    fi
    $(_remote_root_mode_sh(rq))
    if [ \"\$created\" = 1 ]; then
      printf 'CREATED\\n'
    else
      printf 'EXISTED\\n'
    fi
    """
end

"""Ensure `remote_root` exists for ship. Returns `(; abs_root, created)`.

A layout that starts with `~` may create missing components under the remote
home. An absolute layout requires the parent and creates only the final
component (same rule as [`create_remote_roots!`](@ref)). Does not instantiate.

For `~/…`, the deploy path is re-homed onto `cd -P ~ && pwd -P` so a symlinked
\$HOME does not make a logical expansion look outside the physical home.
"""
function _ensure_ship_remote_root!(
        host::AbstractString,
        remote_root::AbstractString,
    )::NamedTuple{(:abs_root, :created), Tuple{String, Bool}}
    layout = strip(String(remote_root))
    isempty(layout) && throw(ArgumentError("remote_root is empty"))
    abs_root, script = if startswith(layout, "~")
        physical_home = _remote_home(host; physical = true)
        logical_home = _remote_home(host; physical = false)
        expanded = _expand_remote_root_abs(host, layout)
        rooted = _rehome_logical_under_physical_home(
            expanded, logical_home, physical_home,
        )
        rooted = validate_expanded_remote_root(rooted, physical_home)
        rooted, _remote_root_ensure_under_home_script(rooted, physical_home)
    else
        rooted = _probe_expanded_remote_root(host, layout)
        startswith(rooted, "/") || throw(
            ArgumentError(
                "ship remote_root must be absolute or ~/…; got $(repr(layout))",
            ),
        )
        rooted, _remote_root_create_script(rooted; report = true)
    end
    code, out = _remote_shell_status(String(host), script)
    if code != 0
        msg = strip(out)
        isempty(msg) && (msg = "remote_root ensure failed")
        throw(ArgumentError(msg))
    end
    created = occursin(r"(^|\n)CREATED(\n|$)", out)
    return (; abs_root = abs_root, created = created)
end

function create_remote_roots!(
        hosts::AbstractVector{<:AbstractString},
        abs_path::AbstractString;
        confirm::Bool = true,
    )
    path = explicit_remote_root_path(abs_path)
    script = _remote_root_create_script(path)
    host_list = String[String(h) for h in hosts]
    isempty(host_list) && throw(ArgumentError("setup --remote-root: no hosts"))
    if confirm && !kit_noninteractive()
        cancelled = with_kit_progress_suspended() do
            writeln_both("remote-root $(path) on $(length(host_list)) host(s)")
            if !kit_confirm("Type 'remote-root' to confirm: "; keyword = "remote-root")
                println_fatal("Cancelled.")
                return true
            end
            println_fatal()
            return false
        end
        if cancelled
            return (;
                cancelled = true,
                succeeded = 0,
                failed = 0,
                hosts = HostResult[],
            )
        end
    end
    n = length(host_list)
    host_results = Vector{HostResult}(undef, n)
    map_host_jobs(host_list) do i, host
        host_results[i] = _setup_host_call!(host) do
            try
                code, out = _remote_shell_status(String(host), script)
                if code != 0
                    msg = strip(out)
                    isempty(msg) && (msg = "remote_root failed")
                    return HostResult(String(host), false, msg)
                end
                return HostResult(String(host), true, "remote_root ok")
            catch e
                e isa InterruptException && rethrow()
                return HostResult(String(host), false, sprint(showerror, e))
            end
        end
    end
    ok_n = count(hr -> hr.ok, host_results)
    return (;
        cancelled = false,
        succeeded = ok_n,
        failed = n - ok_n,
        hosts = host_results,
    )
end

function _remote_run_leaf_script(abs_root::AbstractString, run_id::AbstractString)::String
    runs = _posix_join(abs_root, "runs")
    leaf = _posix_join(runs, run_id)
    src = _posix_join(leaf, "src")
    out = _posix_join(leaf, "out")
    rq = _remote_shell_path_word(runs)
    lq = _remote_shell_path_word(leaf)
    sq = _remote_shell_path_word(src)
    oq = _remote_shell_path_word(out)
    rootq = _remote_shell_path_word(abs_root)
    script = """
    $(_remote_root_mode_sh(rootq))
    if [ ! -d $rq ]; then
      mkdir $rq || [ -d $rq ] || exit 1
    fi
    mkdir $lq || { printf 'run_id already exists: %s\\n' $lq >&2; exit 2; }
    if test -L $sq; then
      printf 'refusing symlinked extract dest %s\\n' $sq >&2
      exit 3
    fi
    if test -e $sq; then
      if test -d $sq; then
        if test -n "\$(ls -A $sq 2>/dev/null)"; then
          printf 'extract dest is not empty: %s\\n' $sq >&2
          exit 4
        fi
      else
        printf 'extract dest exists and is not a directory: %s\\n' $sq >&2
        exit 4
      fi
    fi
    if test -L $oq; then
      printf 'refusing symlinked out dir %s\\n' $oq >&2
      exit 3
    fi
    if test -e $oq; then
      if test -d $oq; then
        if ! out_entries="\$(ls -A $oq 2>/dev/null)"; then
          printf 'could not inspect out dir: %s\\n' $oq >&2
          exit 4
        fi
        if test -n "\$out_entries"; then
          printf 'out dir is not empty: %s\\n' $oq >&2
          exit 4
        fi
      else
        printf 'out path exists and is not a directory: %s\\n' $oq >&2
        exit 4
      fi
    else
      mkdir $oq || exit 1
    fi
    """
    return script
end

"""Minimal remote-leaf `run.toml` for ownership proof (no paths or secrets)."""
function _ship_run_leaf_stamp_toml()::String
    return string(
        "schema = 1\n",
        "writer = \"DistSSHRun $(dist_ssh_kit_version())\"\n",
        "kind = \"ship\"\n",
    )
end

"""Ownership stamp plus completion fields written only after extract succeeds."""
function _ship_run_leaf_complete_toml(content_tree_hash::AbstractString)::String
    return string(
        _ship_run_leaf_stamp_toml(),
        "complete = true\n",
        "algorithm = \"git-sha1\"\n",
        "content_tree_hash = $(repr(String(content_tree_hash)))\n",
    )
end

function _remote_run_leaf_stamp_sh(leaf::AbstractString)::String
    dest = _remote_shell_path_word(_posix_join(leaf, "run.toml"))
    cq = posix_quote(_ship_run_leaf_stamp_toml())
    return """
    printf '%s\\n' $cq > $dest || exit 1
    """
end

function _remote_run_leaf_complete_sh(
        leaf::AbstractString,
        content_tree_hash::AbstractString,
    )::String
    dest = _remote_shell_path_word(_posix_join(leaf, "run.toml"))
    cq = posix_quote(_ship_run_leaf_complete_toml(content_tree_hash))
    return """
    printf '%s\\n' $cq > $dest || exit 1
    """
end

function _remote_prepare_run_leaf!(host::AbstractString, abs_root::AbstractString, run_id::AbstractString)
    leaf = _posix_join(_posix_join(abs_root, "runs"), run_id)
    script = _remote_run_leaf_script(abs_root, run_id) * _remote_run_leaf_stamp_sh(leaf)
    code, out = _remote_shell_status(String(host), script)
    code == 0 || throw(ArgumentError("could not create run dir on $(host): $(strip(out))"))
    return _posix_join(leaf, "src")
end

function _remote_extract_tar!(
        host::AbstractString,
        src::AbstractString,
        tar_path::AbstractString,
        julia_bin::AbstractString,
    )
    sq = _remote_shell_path_word(src)
    inner = _remote_stdlib_julia_e(
        julia_bin,
        "using Tar; isdir(ARGS[1]) || mkdir(ARGS[1]); Tar.extract(stdin, ARGS[1])";
        args = String[sq],
    )
    err_buf = IOBuffer()
    out_buf = IOBuffer()
    cmd = _host_sync_remote_shell_cmd(String(host), inner; forward_stdin = true)
    proc = open(tar_path) do io
        return run(
            pipeline(ignorestatus(cmd); stdin = io, stdout = out_buf, stderr = err_buf);
            wait = true,
        )
    end
    code = DistSSHBase.shell_status(proc)
    err = String(take!(err_buf))
    out = String(take!(out_buf))
    if code == 255
        throw(ArgumentError(summarize_ssh_error(Base.ProcessFailedException(Base.Process[proc]); stderr = err)))
    end
    code == 0 || DistSSHBase._throw_if_nonposix_shell(String(host), code, err)
    code == 0 || throw(ArgumentError("tar extract failed on $(host): $(strip(err) * strip(out))"))
    filled, _ = _remote_shell_status(
        String(host),
        "test -n \"\$(ls -A $sq 2>/dev/null)\"",
    )
    filled == 0 || throw(ArgumentError("tar extract left empty dest on $(host): $src"))
    return nothing
end

"""
    ship(snapshot, hosts, remote_root; confirm=false, record=true) -> ShipTreeResult

Send `snapshot`'s tar to `runs/<run_id>/src/` on each host. Does not pack again
and does not delete the tar.

The tar is hashed again immediately before sending. A different `git-sha1`
tree hash, or a missing tar, throws `ArgumentError`. Depot preferences that
would apply and are not in the ship are refused here. `confirm=false` does
not prompt. `record=false` does not keep this ship for controller `run.toml`
in this process.
"""
function ship(
        snapshot::ShipSnapshot,
        hosts::Vector{String},
        remote_root::AbstractString;
        confirm::Bool = false,
        record::Bool = true,
        report::Bool = false,
        path_anchor::AbstractString = snapshot.local_root,
        run_id::Union{Nothing, AbstractString} = nothing,
        julia = nothing,
        await_inputs::Bool = true,
    )::ShipTreeResult
    isempty(hosts) && throw(ArgumentError("ship-tree: no hosts"))
    length(unique(hosts)) == length(hosts) ||
        throw(ArgumentError("ship-tree: hosts must be unique"))
    rid = run_id === nothing ? allocate_remote_run_id() : validate_run_id(run_id)
    src_logical = _posix_join(String(remote_root), "runs", rid, "src")
    _refuse_unshipped_depot_prefs!()
    if !isempty(_load_ship_inputs(snapshot.root)) && kit_run_dir() === nothing
        throw(
            ArgumentError(
                "ship-tree: declared inputs need DISTSSHKIT_RUN_DIR; refusing to write next to the project",
            ),
        )
    end
    if confirm && !kit_noninteractive()
        cancelled = with_kit_progress_suspended() do
            writeln_both(
                "ship-tree $(display_path(path_anchor, snapshot.local_root)) to $(length(hosts)) host(s) into runs/$rid/src/",
            )
            writeln_both(
                "  files=$(snapshot.files) bytes=$(snapshot.bytes) hash=$(snapshot.content_tree_hash)",
            )
            if !kit_confirm("Type 'ship-tree' to confirm: "; keyword = "ship-tree")
                println_fatal("Cancelled.")
                return true
            end
            println_fatal()
            return false
        end
        cancelled && return ShipTreeResult(
            rid, String(remote_root), src_logical, snapshot.content_tree_hash, "git-sha1",
            snapshot.bytes, snapshot.files, snapshot.tree_matches_head,
            snapshot.external_symlinks_allowed, HostResult[], true,
        )
    end
    _require_snapshot_unchanged!(snapshot)
    n = length(hosts)
    host_results = Vector{HostResult}(undef, n)
    map_host_jobs(hosts) do i, host
        host_results[i] = _setup_host_call!(host) do
            try
                ensured = _ensure_ship_remote_root!(host, remote_root)
                abs_root = ensured.abs_root
                if report
                    kit_println(
                        "  $host: remote_root $(abs_root) (" *
                            (ensured.created ? "created" : "existed") * ")",
                    )
                end
                src = _remote_prepare_run_leaf!(host, abs_root, rid)
                pinned = something(pin_remote_julia(host, julia), resolve_remote_julia(host, julia))
                pinned === nothing && throw(ArgumentError("Julia not found on $host"))
                _remote_extract_tar!(host, src, snapshot.tar_path, pinned)
                leaf = _posix_join(abs_root, "runs", rid)
                code_c, out_c = _remote_shell_status(
                    String(host),
                    _remote_run_leaf_complete_sh(leaf, snapshot.content_tree_hash),
                )
                code_c == 0 || throw(
                    ArgumentError(
                        "could not mark snapshot complete on $(host): $(strip(out_c))",
                    ),
                )
                if await_inputs
                    _record_remote_inputs!(host, abs_root, snapshot.root, pinned)
                else
                    _start_remote_input_hashes!(host, abs_root, snapshot.root, pinned)
                end
                if report
                    kit_print("  $host: ")
                    print_ok("✓")
                    kit_println()
                end
                msg = ensured.created ? "ship-tree ok (created remote_root)" :
                    "ship-tree ok"
                return HostResult(host, true, msg)
            catch e
                if report
                    kit_print("  $host: ")
                    print_err("✗")
                    kit_println()
                end
                return HostResult(host, false, sprint(showerror, e))
            end
        end
    end
    ok_hosts = String[String(hr.host) for hr in host_results if hr.ok]
    rec = Dict{String, Any}(
        "algorithm" => "git-sha1",
        "content_tree_hash" => snapshot.content_tree_hash,
        "bytes" => snapshot.bytes,
        "files" => snapshot.files,
        "run_id" => rid,
        "src" => src_logical,
        "host" => _record_host_alias(first(hosts)),
        "hosts" => ok_hosts,
        "remote_root" => String(remote_root),
        "run_dir_empty_at_start" => true,
    )
    snapshot.external_symlinks_allowed && (rec["external_symlinks_allowed"] = true)
    # `nothing` means the tar was not compared to a git tree. Omit the key.
    snapshot.tree_matches_head === true && (rec["tree_matches_head"] = true)
    if record && !isempty(ok_hosts)
        _LAST_SHIP[] = rec
        _SHIP_LAYOUT_ACTIVE[] = true
        try
            env = resolve_pkg_env(snapshot.root)
            write_last_snapshot_record!(
                env.env_dir,
                String(remote_root),
                ok_hosts,
                rid;
                content_tree_hash = snapshot.content_tree_hash,
            )
        catch e
            e isa InterruptException && rethrow()
            # Record is a convenience default; ship itself already succeeded.
        end
        _set_active_selection!(
            SnapshotSelection(
                :snapshot,
                rid,
                String(remote_root),
                src_logical,
                snapshot.content_tree_hash,
                ok_hosts,
            ),
        )
    end
    return ShipTreeResult(
        rid, String(remote_root), src_logical, snapshot.content_tree_hash, "git-sha1",
        snapshot.bytes, snapshot.files, snapshot.tree_matches_head,
        snapshot.external_symlinks_allowed, host_results, false,
    )
end
public ship

function ship_project_to_hosts!(
        hosts::Vector{String},
        local_root::AbstractString,
        remote_root::AbstractString;
        confirm::Bool = true,
        report::Bool = false,
        path_anchor::AbstractString = local_root,
        allow_external_symlinks::Bool = false,
        ship_max_bytes::Integer = SHIP_MAX_BYTES_DEFAULT,
        run_id::Union{Nothing, AbstractString} = nothing,
        julia = nothing,
        await_inputs::Bool = true,
    )::ShipTreeResult
    isempty(hosts) && throw(ArgumentError("ship-tree: no hosts"))
    length(unique(hosts)) == length(hosts) ||
        throw(ArgumentError("ship-tree: hosts must be unique"))
    warn_project_sshflags(canonical_local_path(local_root))
    snap = snapshot(
        local_root;
        allow_external_symlinks = allow_external_symlinks,
        ship_max_bytes = ship_max_bytes,
    )
    try
        return ship(
            snap, hosts, remote_root;
            confirm = confirm,
            record = true,
            report = report,
            path_anchor = path_anchor,
            run_id = run_id,
            julia = julia,
            await_inputs = await_inputs,
        )
    finally
        rm(snapshot_directory(snap); force = true, recursive = true)
    end
end

function warn_project_sshflags(project::AbstractString)
    _SSHFLAGS_WARNED[] && return nothing
    d = canonical_local_path(project)
    hits = String[]
    pf = joinpath(d, "Project.toml")
    if isfile(pf)
        raw = try
            TOML.parsefile(pf)
        catch
            nothing
        end
        if raw isa AbstractDict && haskey(raw, "sshflags")
            push!(hits, "Project.toml sshflags")
        end
    end
    for rel in (".distsshkit/sshflags", ".distsshkit/config.toml")
        p = joinpath(d, rel)
        isfile(p) || continue
        if rel == ".distsshkit/sshflags"
            push!(hits, rel)
            continue
        end
        raw = try
            TOML.parsefile(p)
        catch
            nothing
        end
        if raw isa AbstractDict && (
                haskey(raw, "sshflags") ||
                    haskey(get(raw, "ssh", Dict()), "sshflags")
            )
            push!(hits, rel)
        end
    end
    isempty(hits) && return nothing
    _SSHFLAGS_WARNED[] = true
    @warn "project-local sshflags ($(join(hits, ", "))) are ignored; SSH uses DISTRIBUTED_SSH_OPTS / ssh_opts()"
    return nothing
end
