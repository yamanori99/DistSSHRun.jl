# Tar ship of a git work tree into `<remote_root>/runs/<run_id>/src/`.

const SHIP_MAX_BYTES_DEFAULT = 256 * 1024 * 1024
const SHIP_FILE_WARN_BYTES = 50 * 1024 * 1024

const _LAST_SHIP = Ref{Union{Nothing, Dict{String, Any}}}(nothing)
const _SHIP_LAYOUT_ACTIVE = Ref(false)
const _OPENRSYNC_WARNED = Ref(false)
const _SSHFLAGS_WARNED = Ref(false)

struct ShipTreeResult
    run_id::String
    remote_root::String
    src::String
    content_tree_hash::String
    algorithm::String
    bytes::Int
    files::Int
    tree_matches_head::Bool
    external_symlinks_allowed::Bool
    host_results::Vector{HostResult}
    cancelled::Bool
end

function last_ship_result()::Union{Nothing, Dict{String, Any}}
    return _LAST_SHIP[]
end

function _clear_last_ship!()
    _LAST_SHIP[] = nothing
    _SHIP_LAYOUT_ACTIVE[] = false
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

function _ship_rel_paths(local_root::AbstractString)::Vector{String}
    root = canonical_local_path(local_root)
    env0 = resolve_pkg_env(root)
    send_list = _rsync_send_list(env0.env_dir, env0; warn = true)
    send_list === nothing && throw(
        ArgumentError(
            "ship-tree requires a git work tree (git ls-files -co --exclude-standard)",
        ),
    )
    ensure_manifest_ships!(
        root; send_list = send_list, warn_send_list = true,
    )
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
    _append_project_preference_rels!(root, out)
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

function _remote_input_probe_sh(abs_path::AbstractString, do_hash::Bool)::String
    q = _remote_shell_path_word(abs_path)
    walk = do_hash ? _remote_input_hash_walk() : _remote_input_stat_walk()
    return """
        set -eu
        if [ ! -e $q ] && [ ! -L $q ]; then printf '%s\\n' missing; exit 2; fi
        if [ -L $q ]; then
          _f=$q
        $(_remote_input_readlink_sh())
        fi
        _dsk_hex() {
          _line=
          if command -v sha256sum >/dev/null 2>&1; then
            _line=\$(sha256sum "\$1") || return 1
          else
            _line=\$(shasum -a 256 "\$1") || return 1
          fi
          _hex=\$(printf '%s\\n' "\$_line" | awk '{ print \$1; exit }')
          printf '%s' "\$_hex" | awk 'length(\$0)==64 && \$0 ~ /^[0-9a-fA-F]+\$/ { found=1 } END { exit found ? 0 : 1 }' || return 1
          printf '%s\\n' "\$_hex"
        }
        _dsk_stat() {
          stat -c '%s %Y' "\$1" 2>/dev/null && return 0
          stat -f '%z %m' "\$1"
        }
        if [ -d $q ]; then
          _paths=\$(mktemp)
          _sorted=\$(mktemp)
          _rows=\$(mktemp)
          trap 'rm -f "\$_paths" "\$_sorted" "\$_rows"' EXIT
          cd $q || exit 1
          find . '(' -type f -o -type l ')' -path '*
    *' -print -quit > "\$_paths" || exit 1
          if [ -s "\$_paths" ]; then
            printf '%s\\n' 'input filename contains a newline'
            exit 2
          fi
          find . -type f > "\$_paths" || exit 1
          find . -type l >> "\$_paths" || exit 1
          LC_ALL=C sort -o "\$_sorted" "\$_paths" || exit 1
          : > "\$_rows"
        $walk
        elif [ -f $q ]; then
        $(
        if do_hash
            """
              if [ -L $q ]; then
                printf 'link\\t%s\\t.\\n' "\$_target"
              else
            $(_remote_input_file_branch(q, true))
              fi
                    """
        else
            _remote_input_file_branch(q, false)
        end
    )
        else
          printf '%s\\n' 'not a file or directory'
          exit 2
        fi
        """
end

function _remote_input_file_branch(q::AbstractString, do_hash::Bool)::String
    if do_hash
        return """
          _st=\$(_dsk_stat $q) || exit 1
          _size=\$(printf '%s\\n' "\$_st" | awk '{ print \$1; exit }')
          [ -n "\$_size" ] || exit 1
          _sum=\$(_dsk_hex $q) || exit 1
          printf 'PROG %s %s\\n' "\$_size" "\$_size" >&2
          printf 'file\\t%s\\t%s\\t.\\n' "\$_size" "\$_sum"
        """
    end
    return """
      _st=\$(_dsk_stat $q) || exit 1
      _size=\$(printf '%s\\n' "\$_st" | awk '{ print \$1; exit }')
      _mtime=\$(printf '%s\\n' "\$_st" | awk '{ print \$2; exit }')
      [ -n "\$_size" ] && [ -n "\$_mtime" ] || exit 1
      _one=\$(mktemp)
      trap 'rm -f "\$_one"' EXIT
      printf '.\\tfile\\t%s\\t%s\\n' "\$_size" "\$_mtime" > "\$_one"
      _sum=\$(_dsk_hex "\$_one") || exit 1
      printf 'files=1 bytes=%s newest=%s digest=%s\\n' "\$_size" "\$_mtime" "\$_sum"
    """
end

"""`readlink` into `\$_target`. A tab or newline in the link text is refused.

Command substitution drops trailing newlines from `readlink`. Compare the
byte length to `stat` on the symlink; a shorter value means a trailing
newline was stripped. An embedded newline still fails the awk check.
"""
function _remote_input_readlink_sh()::String
    return """
          _linklen=\$(stat -c '%s' "\$_f" 2>/dev/null || stat -f '%z' "\$_f") || exit 1
          _target=\$(readlink "\$_f") || exit 1
          _got=\$(printf '%s' "\$_target" | wc -c | tr -d ' ')
          [ "\$_got" -eq "\$_linklen" ] || {
            printf '%s\\n' 'input link target contains a newline'
            exit 2
          }
          printf '%s' "\$_target" | awk 'BEGIN { bad = 0 } index(\$0, "\\t") { bad = 1 } END { if (NR > 1 || bad) exit 2 }' || {
            printf '%s\\n' 'input link target contains a newline'
            exit 2
          }
    """
end

function _remote_input_hash_walk()::String
    return """
      _total=0
      while IFS= read -r _f; do
        [ -n "\$_f" ] || continue
        [ -L "\$_f" ] && continue
        _st=\$(_dsk_stat "\$_f") || exit 1
        _size=\$(printf '%s\\n' "\$_st" | awk '{ print \$1; exit }')
        [ -n "\$_size" ] || exit 1
        _total=\$((_total + _size))
      done < "\$_sorted"
      _done=0
      while IFS= read -r _f; do
        [ -n "\$_f" ] || continue
        _rel=\${_f#./}
        if [ -L "\$_f" ]; then
        $(_remote_input_readlink_sh())
          printf 'link\\t%s\\t%s\\n' "\$_target" "\$_rel"
        else
          _st=\$(_dsk_stat "\$_f") || exit 1
          _size=\$(printf '%s\\n' "\$_st" | awk '{ print \$1; exit }')
          [ -n "\$_size" ] || exit 1
          _hex=\$(_dsk_hex "\$_f") || exit 1
          _done=\$((_done + _size))
          printf 'file\\t%s\\t%s\\t%s\\n' "\$_size" "\$_hex" "\$_rel"
          printf 'PROG %s %s\\n' "\$_done" "\$_total" >&2
        fi
      done < "\$_sorted"
    """
end

function _remote_input_stat_walk()::String
    return """
      _files=0
      _bytes=0
      _newest=0
      while IFS= read -r _f; do
        [ -n "\$_f" ] || continue
        _rel=\${_f#./}
        _st=\$(_dsk_stat "\$_f") || exit 1
        _size=\$(printf '%s\\n' "\$_st" | awk '{ print \$1; exit }')
        _mtime=\$(printf '%s\\n' "\$_st" | awk '{ print \$2; exit }')
        [ -n "\$_size" ] && [ -n "\$_mtime" ] || exit 1
        if [ -L "\$_f" ]; then
        $(_remote_input_readlink_sh())
          printf '%s\\tlink\\t%s\\t%s\\t%s\\n' "\$_rel" "\$_size" "\$_mtime" "\$_target" >> "\$_rows" || exit 1
        else
          _files=\$((_files + 1))
          _bytes=\$((_bytes + _size))
          printf '%s\\tfile\\t%s\\t%s\\n' "\$_rel" "\$_size" "\$_mtime" >> "\$_rows" || exit 1
        fi
        if [ "\$_mtime" -gt "\$_newest" ]; then _newest=\$_mtime; fi
      done < "\$_sorted"
      _sum=\$(_dsk_hex "\$_rows") || exit 1
      printf 'files=%s bytes=%s newest=%s digest=%s\\n' "\$_files" "\$_bytes" "\$_newest" "\$_sum"
    """
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
            _sha256_hex(read(full))
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
    code = Int(something(proc.exitcode, 1))
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

function _record_remote_inputs!(
        host::AbstractString,
        abs_root::AbstractString,
        local_root::AbstractString,
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
            _remote_input_probe_sh(remote, input.hash),
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

function _ship_bytes_and_files(root::AbstractString, rels::Vector{String})
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
        sz > SHIP_FILE_WARN_BYTES && @warn "ship-tree: $rel is $(sz) bytes (> 50 MiB)"
    end
    return total, nfiles, sizes
end

function _head_tree(root::AbstractString)::Union{Nothing, String}
    git = Sys.which("git")
    git === nothing && return nothing
    out = try
        strip(read(Cmd([git, "-C", root, "rev-parse", "HEAD^{tree}"]), String))
    catch
        return nothing
    end
    return isempty(out) ? nothing : String(out)
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
    env0 = resolve_pkg_env(local_dir)
    root = ensure_manifest_ships!(
        local_dir;
        send_list = _rsync_send_list(env0.env_dir, env0; warn = true),
        warn_send_list = true,
    ).env_dir
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
        head = _head_tree(root)
        return (
            tar_path = tar_path,
            tmpd = tmpd,
            hash = String(hash),
            bytes = total,
            files = nfiles,
            tree_matches_head = head !== nothing && head == hash,
            external_symlinks = allowed_links,
            root = root,
        )
    catch
        rm(tmpd; force = true, recursive = true)
        rethrow()
    end
end

const _PROJECT_PREFERENCE_NAMES = ("LocalPreferences.toml", "JuliaLocalPreferences.toml")

"""Add preference files that sit next to a shipped `Project.toml`, even when gitignored."""
function _append_project_preference_rels!(root::AbstractString, out::Vector{String})
    projects = String[]
    for rel in out
        (rel == "Project.toml" || endswith(rel, "/Project.toml")) && push!(projects, rel)
    end
    for rel in projects
        dir = dirname(rel)
        for name in _PROJECT_PREFERENCE_NAMES
            pref = dir == "" || dir == "." ? name : dir * "/" * name
            path = joinpath(root, pref)
            islink(path) && throw(
                ArgumentError("ship-tree: symlinked project preference is not supported: $pref"),
            )
            isfile(path) || continue
            pref in out || push!(out, pref)
        end
    end
    return nothing
end

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

function _probe_expanded_remote_root(host::AbstractString, remote_root::AbstractString)::String
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
    code, home_out = _remote_shell_status(String(host), "cd -P ~ && pwd -P")
    code == 0 || throw(ArgumentError("could not resolve \$HOME on $(host)"))
    home = strip(home_out)
    isempty(home) && throw(ArgumentError("could not resolve \$HOME on $(host)"))
    return validate_expanded_remote_root(String(abs_root), String(home))
end

"""Project cwd on `host`: `remote_root` when it has `Project.toml`, else latest `runs/*/src`."""
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
    if test -f $rq/Project.toml; then
      printf '%s\\n' $rq
      exit 0
    fi
    latest=\$(ls -1d $rq/runs/*/src 2>/dev/null | sort | tail -n 1)
    if test -n "\$latest" && test -f "\$latest/Project.toml"; then
      printf '%s\\n' "\$latest"
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
    String(stored) == String(remote_root) || return nothing
    return src
end

function _work_root_for_hosts(
        hosts::AbstractVector{<:AbstractString},
        remote_root::AbstractString,
    )::String
    src = _last_ship_src_for(hosts, remote_root)
    src !== nothing && return src
    isempty(hosts) && return String(remote_root)
    host = first(hosts)
    try
        validate_ssh_host(host)
    catch
        return String(remote_root)
    end
    try
        return _remote_project_work_root(host, remote_root)
    catch e
        e isa InterruptException && rethrow()
        return String(remote_root)
    end
end

"""Worker `--project` after ship: last-ship `src` under the deploy root, plus member rel.

`_last_ship_src_for` matches `remote_deploy_root`, not `session_remote_root`.
A workspace member is then joined onto that `src`.
"""
function _project_work_root(
        hosts::AbstractVector{<:AbstractString},
        local_project::AbstractString;
        cli_override::Union{Nothing, AbstractString} = nothing,
    )::String
    deploy = remote_deploy_root(local_project; cli_override = cli_override)
    mapped = resolve_remote_project_root(local_project; cli_override = cli_override)
    wr = _work_root_for_hosts(hosts, deploy)
    return _rehome_under_work_root(mapped, deploy, wr)
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

"""`remote_layout_path` re-homed onto the remote work root for `hosts`."""
function _remote_work_layout_path(
        local_abs::AbstractString,
        local_repo::AbstractString,
        hosts::AbstractVector{<:AbstractString},
    )::String
    mapped = remote_layout_path(local_abs, local_repo)
    deploy = remote_deploy_root(local_repo)
    wr = _work_root_for_hosts(hosts, deploy)
    return _rehome_under_work_root(mapped, deploy, wr)
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
"""
function _remote_root_create_script(abs_path::AbstractString)::String
    path = explicit_remote_root_path(abs_path)
    q = _remote_shell_path_word(path)
    parent = dirname(path)
    pq = _remote_shell_path_word(parent)
    return """
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
      mkdir -m 700 $q || exit 1
      chmod go-w $q || exit 1
    fi
    $(_remote_root_mode_sh(q))
    """
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

function _remote_prepare_run_leaf!(host::AbstractString, abs_root::AbstractString, run_id::AbstractString)
    script = _remote_run_leaf_script(abs_root, run_id)
    code, out = _remote_shell_status(String(host), script)
    code == 0 || throw(ArgumentError("could not create run dir on $(host): $(strip(out))"))
    return _posix_join(_posix_join(_posix_join(abs_root, "runs"), run_id), "src")
end

function _remote_extract_tar!(
        host::AbstractString,
        src::AbstractString,
        tar_path::AbstractString,
        julia_bin::AbstractString,
    )
    sq = _remote_shell_path_word(src)
    jb = _remote_julia_path_sh(julia_bin)
    inner = string(
        jb,
        " --startup-file=no -e ",
        posix_quote("using Tar; isdir(ARGS[1]) || mkdir(ARGS[1]); Tar.extract(stdin, ARGS[1])"),
        " -- ",
        sq,
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
    code = Int(something(proc.exitcode, 1))
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
    )::ShipTreeResult
    isempty(hosts) && throw(ArgumentError("ship-tree: no hosts"))
    length(unique(hosts)) == length(hosts) ||
        throw(ArgumentError("ship-tree: hosts must be unique"))
    rid = run_id === nothing ? allocate_remote_run_id() : validate_run_id(run_id)
    src_logical = _posix_join(String(remote_root), "runs", rid, "src")
    warn_project_sshflags(canonical_local_path(local_root))
    _refuse_unshipped_depot_prefs!()
    packed = pack_ship_tar(
        local_root;
        allow_external_symlinks = allow_external_symlinks,
        ship_max_bytes = ship_max_bytes,
    )
    try
        if !isempty(_load_ship_inputs(packed.root)) && kit_run_dir() === nothing
            throw(
                ArgumentError(
                    "ship-tree: declared inputs need DISTSSHKIT_RUN_DIR; refusing to write next to the project",
                ),
            )
        end
        if confirm && !kit_noninteractive()
            cancelled = with_kit_progress_suspended() do
                writeln_both(
                    "ship-tree $(display_path(path_anchor, local_root)) to $(length(hosts)) host(s) into runs/$rid/src/",
                )
                writeln_both("  files=$(packed.files) bytes=$(packed.bytes) hash=$(packed.hash)")
                if !kit_confirm("Type 'ship-tree' to confirm: "; keyword = "ship-tree")
                    println_fatal("Cancelled.")
                    return true
                end
                println_fatal()
                return false
            end
            cancelled && return ShipTreeResult(
                rid, String(remote_root), src_logical, packed.hash, "git-sha1",
                packed.bytes, packed.files, packed.tree_matches_head,
                allow_external_symlinks, HostResult[], true,
            )
        end
        n = length(hosts)
        host_results = Vector{HostResult}(undef, n)
        map_host_jobs(hosts) do i, host
            host_results[i] = _setup_host_call!(host) do
                try
                    abs_root = _probe_expanded_remote_root(host, remote_root)
                    src = _remote_prepare_run_leaf!(host, abs_root, rid)
                    pinned = something(pin_remote_julia(host, julia), resolve_remote_julia(host, julia))
                    pinned === nothing && throw(ArgumentError("Julia not found on $host"))
                    _remote_extract_tar!(host, src, packed.tar_path, pinned)
                    _record_remote_inputs!(host, abs_root, packed.root)
                    if report
                        kit_print("  $host: ")
                        print_ok("✓")
                        kit_println()
                    end
                    return HostResult(host, true, "ship-tree ok")
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
            "content_tree_hash" => packed.hash,
            "bytes" => packed.bytes,
            "files" => packed.files,
            "run_id" => rid,
            "src" => src_logical,
            "host" => _record_host_alias(first(hosts)),
            "hosts" => ok_hosts,
            "remote_root" => String(remote_root),
            "run_dir_empty_at_start" => true,
        )
        allow_external_symlinks && (rec["external_symlinks_allowed"] = true)
        packed.tree_matches_head && (rec["tree_matches_head"] = true)
        if !isempty(ok_hosts)
            _LAST_SHIP[] = rec
            _SHIP_LAYOUT_ACTIVE[] = true
        end
        return ShipTreeResult(
            rid, String(remote_root), src_logical, packed.hash, "git-sha1",
            packed.bytes, packed.files, packed.tree_matches_head,
            allow_external_symlinks, host_results, false,
        )
    finally
        rm(packed.tmpd; force = true, recursive = true)
    end
end

function warn_openrsync_once()
    _OPENRSYNC_WARNED[] && return nothing
    argv = try
        _host_sync_rsync_argv()
    catch
        return nothing
    end
    # Collect tests spawn `sh` plus `DISTSSHKIT_TEST_RSYNC`. PATH rsync is unused.
    length(argv) == 1 || return nothing
    ver = try
        lowercase(read(`$(argv[1]) --version`, String))
    catch
        return nothing
    end
    occursin("openrsync", ver) || return nothing
    _OPENRSYNC_WARNED[] = true
    @warn "rsync on PATH is openrsync; cache pull uses it, not GNU rsync"
    return nothing
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
