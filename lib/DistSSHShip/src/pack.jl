# One tar whose paths are relative to the ship anchor. The content hash is
# Tar's git tree hash of that tar, so it depends on relative path and content,
# not on the local absolute path.

"""Tar plus the relative layout [`ship`](@ref DistSSHRun.DistSSHShip.ship) extracts."""
struct Shipment
    directory::String
    tar_path::String
    content_tree_hash::String
    bytes::Int
    files::Int
    anchor::String
    project_dir::String
    # `"."` when the tar root is the project directory.
    project_rel::String
    external_symlinks::Vector{String}
    extra_rels::Vector{String}
end

function content_tree_hash(snapshot::Shipment)::String
    return snapshot.content_tree_hash
end

function _lexical_join(base::AbstractString, target::AbstractString)::Vector{String}
    parts = String[]
    if startswith(target, '/')
        return String[p for p in split(target, '/'; keepempty = false)]
    end
    append!(parts, split(_posix(base), '/'; keepempty = false))
    for p in split(_posix(target), '/'; keepempty = false)
        p == "." && continue
        if p == ".."
            isempty(parts) || pop!(parts)
            continue
        end
        push!(parts, p)
    end
    return parts
end

function _symlink_escapes(root::AbstractString, rel::AbstractString, target::AbstractString)::Bool
    startswith(target, '/') && return true
    root_parts = split(_posix(canonical_local_path(root)), '/'; keepempty = false)
    from = joinpath(root, dirname(rel))
    joined = _lexical_join(from, target)
    length(joined) < length(root_parts) && return true
    for (a, b) in zip(root_parts, joined)
        a == b || return true
    end
    return false
end

function _check_symlinks(root::AbstractString, rels::Vector{String}; allow_external::Bool)::Vector{String}
    recorded = String[]
    for rel in rels
        p = joinpath(root, rel)
        islink(p) || continue
        target = readlink(p)
        if _symlink_escapes(root, rel, target)
            allow_external || throw(
                ArgumentError(
                    "escaping symlink $(repr(rel)) -> $(repr(target)); pass --allow-external-symlinks",
                )
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

function _dir_bytes(sizes::Vector{Tuple{Int, String}})::Vector{Pair{String, Int}}
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

function _measure!(
        rels::Vector{Tuple{String, String}},
        ship_max_bytes::Integer;
        warn::Function,
    )::Tuple{Int, Int}
    file_limit = _warn_limit(_SHIP_WARN_FILE_ENV, SHIP_FILE_WARN_BYTES)
    total_limit = _warn_limit(_SHIP_WARN_TOTAL_ENV, SHIP_WARN_TOTAL_BYTES_DEFAULT)
    total = 0
    nfiles = 0
    sizes = Tuple{Int, String}[]
    for (rel, src) in rels
        isfile(src) && !islink(src) || continue
        sz = Int(filesize(src))
        total += sz
        nfiles += 1
        push!(sizes, (sz, rel))
        sz > file_limit && @warn "ship-tree: $rel is $(sz) bytes (> $file_limit bytes)"
    end
    if total > total_limit
        sort!(sizes; by = first, rev = true)
        n = min(10, length(sizes))
        files = join((string(rel, " (", sz, ")") for (sz, rel) in sizes[1:n]), "\n  ")
        dirs = _dir_bytes(sizes)
        nd = min(10, length(dirs))
        dir_lines = nd == 0 ? "" : join((string(rel, " (", sz, ")") for (rel, sz) in dirs[1:nd]), "\n  ")
        msg = "Warning: ship-tree send list is $total bytes (> $total_limit). Largest files:\n  $files\n"
        if !isempty(dir_lines)
            msg *= "Largest directories:\n  $dir_lines\n"
        end
        warn(msg)
    end
    if total > Int(ship_max_bytes)
        sort!(sizes; by = first, rev = true)
        top = join(
            (string(rel, " (", sz, ")") for (sz, rel) in sizes[1:min(10, length(sizes))]),
            "\n  ",
        )
        throw(
            ArgumentError(
                "ship-tree: tree is $total bytes (cap $(Int(ship_max_bytes))). Largest:\n  $top\n.gitignore them or declare data directories (0.3.0).",
            )
        )
    end
    return total, nfiles
end

function _prefix(project_rel::AbstractString, rel::AbstractString)::String
    project_rel == "." && return String(rel)
    return string(project_rel, "/", rel)
end

function _require_manifest(project::ShipProject)
    project.manifest isa String && return nothing
    shown = project.project_dir
    throw(
        ArgumentError(
            "No Manifest for $(repr(shown)). Run: julia --project=$(repr(shown)) -e 'using Pkg; Pkg.resolve()'",
        )
    )
end

function _warn_omitted!(
        project::ShipProject,
        anchor::String,
        deps::Vector{PathDep},
        entries::Vector{Tuple{String, String}},
        prel::String;
        warn::Function,
    )
    included = Set{String}(first(entry) for entry in entries)
    roots = Tuple{String, String}[(canonical_local_path(project.project_dir), prel)]
    for dep in deps
        push!(
            roots, (
                canonical_local_path(dep.dir),
                replace(relpath(_fs_path(dep.dir), _fs_path(anchor)), '\\' => '/'),
            )
        )
    end
    if project.workspace_root isa String
        push!(
            roots, (
                canonical_local_path(project.workspace_root),
                replace(relpath(_fs_path(project.workspace_root), _fs_path(anchor)), '\\' => '/'),
            )
        )
    end
    hits = String[]
    seen = Set{String}()
    for (root, prefix) in roots
        isdir(root) || continue
        stack = [(root, "")]
        while !isempty(stack)
            dir, rel = pop!(stack)
            for name in readdir(dir)
                name == ".git" && continue
                child = joinpath(dir, name)
                child_rel = isempty(rel) ? name : string(rel, "/", name)
                full = prefix == "." || prefix == "" ? child_rel : string(prefix, "/", child_rel)
                if name in ("Project.toml", "JuliaProject.toml", "Manifest.toml") ||
                        startswith(name, "Manifest-v") || startswith(name, "JuliaManifest-v")
                    if !(full in included) && !(full in seen) && path_ignored(root, child_rel, false)
                        push!(seen, full)
                        push!(hits, full)
                    end
                end
                isdir(child) && !islink(child) && push!(stack, (child, child_rel))
            end
        end
    end
    isempty(hits) && return nothing
    sort!(hits)
    joined = length(hits) == 1 ? hits[1] : join(hits, ", ")
    word = length(hits) == 1 ? "file is" : "files are"
    warn("Warning: $joined $word excluded by .gitignore and will not be shipped.\n")
    return nothing
end

"""Follow one symlink. The remote name is the link's basename. The bytes are the target's."""
function _read_extra(path::AbstractString)::Tuple{String, Vector{UInt8}, UInt16}
    raw = canonical_local_path(path)
    ispath(raw) || islink(raw) || throw(
        ArgumentError(
            "extra file does not exist: $raw",
        )
    )
    name = basename(raw)
    isempty(name) && throw(ArgumentError("extra file needs a file name: $raw"))
    if islink(raw)
        target = readlink(raw)
        resolved = isabspath(target) ? target : joinpath(dirname(raw), target)
        islink(resolved) && throw(
            ArgumentError(
                "extra file $raw is a symlink to another symlink ($target). Ship follows one symlink.",
            )
        )
        isfile(resolved) || throw(
            ArgumentError(
                "extra file $raw is not a symlink to a regular file ($target).",
            )
        )
        mode = UInt16(filemode(resolved) & 0o777)
        return name, read(resolved), mode
    end
    isfile(raw) || throw(
        ArgumentError(
            "extra file must be a regular file: $raw",
        )
    )
    isdir(raw) && throw(ArgumentError("extra file must be a regular file: $raw"))
    mode = UInt16(filemode(raw) & 0o777)
    return name, read(raw), mode
end

function _stage_entry!(stage::AbstractString, rel::AbstractString, src::AbstractString)
    dest = joinpath(stage, split(rel, '/'; keepempty = false)...)
    mkpath(dirname(dest))
    if islink(src)
        symlink(readlink(src), dest)
    elseif isdir(src) && !islink(src)
        isdir(dest) || mkdir(dest)
    else
        cp(src, dest; force = false)
    end
    return nothing
end

function _collect_entries(
        project::ShipProject,
        anchor::String,
        deps::Vector{PathDep};
        omit_project_rels::Vector{String},
    )
    entries = Tuple{String, String}[]
    seen = Set{String}()
    function add_tree!(tree_root::AbstractString, prefix::AbstractString; omit::Vector{String} = String[])
        root_c = canonical_local_path(tree_root)
        isdir(root_c) || return nothing
        listed = _selected_paths(root_c; omit = omit)
        for rel in listed
            full = prefix == "" || prefix == "." ? rel : string(prefix, "/", rel)
            full in seen && continue
            push!(seen, full)
            push!(entries, (full, joinpath(root_c, rel)))
        end
        return nothing
    end
    prel = project_relpath(project, anchor)
    add_tree!(project.project_dir, prel; omit = omit_project_rels)
    for dep in deps
        dep_rel = replace(relpath(_fs_path(dep.dir), _fs_path(anchor)), '\\' => '/')
        add_tree!(dep.dir, dep_rel)
    end
    if project.workspace_root isa String
        ws = canonical_local_path(project.workspace_root)
        for file in (DistSSHBase._located_project_file(ws), project.manifest)
            file isa String || continue
            isfile(file) || continue
            rel = replace(relpath(_fs_path(file), _fs_path(anchor)), '\\' => '/')
            rel in seen && continue
            inside = replace(relpath(_fs_path(file), _fs_path(ws)), '\\' => '/')
            if path_ignored(ws, inside, false)
                continue
            end
            push!(seen, rel)
            push!(entries, (rel, file))
        end
    elseif project.manifest isa String && !_contains_dir(project.project_dir, dirname(project.manifest))
        man = project.manifest
        rel = replace(relpath(_fs_path(man), _fs_path(anchor)), '\\' => '/')
        if !(rel in seen) && isfile(man)
            if path_ignored(dirname(man), basename(man), false)
                # Final warning pass names it.
            else
                push!(seen, rel)
                push!(entries, (rel, man))
            end
        end
    end
    return entries, prel
end

"""
    pack_tree(project; extra_files=String[], kwargs...) -> Shipment

Pack `project` (a directory, a project file, or a `--project` spec) into a
temporary tar. The caller deletes `pack.directory`.

`extra_files` has length 0 or 1. The one file is stored at
`<project>/_distsshrun_external/<basename>`. A symlink is followed once:
the archive name is the link name and the bytes are the target. More than
one extra file throws `ArgumentError` (`not yet supported`).

The hash covers project files, path dependencies, and that extra file by
relative path and content.
"""
function pack_tree(
        project::AbstractString;
        script::Union{Nothing, AbstractString} = nothing,
        cwd::AbstractString = pwd(),
        extra_files::Vector{String} = String[],
        allow_external_symlinks::Bool = false,
        ship_max_bytes::Integer = SHIP_MAX_BYTES_DEFAULT,
        omit_project_rels::Vector{String} = String[],
        warn::Function = print,
    )::Shipment
    length(extra_files) > 1 && throw(
        ArgumentError(
            "more than one extra file is not yet supported",
        )
    )
    resolved = resolve_ship_project(String(project); script = script, cwd = cwd)
    _require_manifest(resolved)
    if ispath(joinpath(resolved.project_dir, EXTERNAL_DIR_NAME))
        throw(
            ArgumentError(
                "project $(resolved.project_dir) contains $(EXTERNAL_DIR_NAME), which ship reserves for an external script.",
            )
        )
    end
    deps = path_dependencies(resolved)
    anchor = ship_anchor(resolved, deps)
    entries, prel = _collect_entries(
        resolved, anchor, deps; omit_project_rels = omit_project_rels,
    )
    _warn_omitted!(resolved, anchor, deps, entries, prel; warn = warn)
    extra_rels = String[]
    extra_payload = nothing
    if length(extra_files) == 1
        name, bytes, mode = _read_extra(extra_files[1])
        extra_rel = _prefix(prel, string(EXTERNAL_DIR_NAME, "/", name))
        for entry in entries
            entry[1] == extra_rel || continue
            throw(
                ArgumentError(
                    "extra file collides with a shipped path: $extra_rel",
                )
            )
        end
        push!(extra_rels, extra_rel)
        extra_payload = (extra_rel, bytes, mode)
    end
    rels = String[e[1] for e in entries]
    append!(rels, extra_rels)
    allowed = _check_symlinks(anchor, String[e[1] for e in entries]; allow_external = allow_external_symlinks)
    real_entries = Tuple{String, String}[(rel, src) for (rel, src) in entries]
    total, nfiles = _measure!(real_entries, ship_max_bytes; warn = warn)
    if extra_payload !== nothing
        total += length(extra_payload[2])
        nfiles += 1
        if total > Int(ship_max_bytes)
            throw(
                ArgumentError(
                    "ship-tree: tree is $total bytes (cap $(Int(ship_max_bytes))).",
                )
            )
        end
    end
    isempty(rels) && throw(ArgumentError("nothing to ship from $(resolved.project_dir)"))
    tmpd = mktempdir()
    stage = joinpath(tmpd, "stage")
    mkdir(stage)
    tar_path = joinpath(tmpd, "ship.tar")
    try
        for (rel, src) in entries
            _stage_entry!(stage, rel, src)
        end
        if extra_payload !== nothing
            rel, bytes, mode = extra_payload
            dest = joinpath(stage, split(rel, '/'; keepempty = false)...)
            mkpath(dirname(dest))
            write(dest, bytes)
            chmod(dest, mode)
        end
        Tar.create(stage, tar_path)
        hash = String(Tar.tree_hash(tar_path; algorithm = TREE_HASH_ALGORITHM, skip_empty = true))
        return Shipment(
            tmpd, tar_path, hash, total, nfiles, anchor, resolved.project_dir,
            prel, allowed, extra_rels,
        )
    catch
        rm(tmpd; force = true, recursive = true)
        rethrow()
    end
end

function script_relpath(project_dir::AbstractString, script::AbstractString)::String
    proj = canonical_local_path(project_dir)
    path = canonical_local_path(script)
    prefix = joinpath(proj, "")
    if startswith(path, prefix) || path == proj
        rel = relpath(path, proj)
        return rel == "." ? basename(path) : replace(rel, '\\' => '/')
    end
    return string(EXTERNAL_DIR_NAME, "/", basename(path))
end

function script_outside_project(project_dir::AbstractString, script::AbstractString)::Bool
    proj = canonical_local_path(project_dir)
    path = canonical_local_path(script)
    prefix = joinpath(proj, "")
    return !(startswith(path, prefix) || path == proj)
end
