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
    filter!(rel -> !_ship_unshippable(joinpath(root, rel)), out)
    sort!(out)
    isempty(out) && throw(ArgumentError("nothing to ship from $root"))
    return out
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

function _warn_ignored_local_preferences(root::AbstractString)
    for name in ("LocalPreferences.toml", "JuliaLocalPreferences.toml")
        p = joinpath(root, name)
        isfile(p) || continue
        git = Sys.which("git")
        git === nothing && continue
        ignored = try
            success(
                pipeline(
                    `$git -C $root check-ignore -q $name`;
                    stdout = devnull, stderr = devnull,
                ),
            )
        catch
            false
        end
        ignored && @warn "ship-tree: $name is gitignored and will not be shipped"
    end
    return nothing
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

function _remote_prepare_run_leaf!(host::AbstractString, abs_root::AbstractString, run_id::AbstractString)
    runs = _posix_join(abs_root, "runs")
    leaf = _posix_join(runs, run_id)
    src = _posix_join(leaf, "src")
    rq = _remote_shell_path_word(runs)
    lq = _remote_shell_path_word(leaf)
    sq = _remote_shell_path_word(src)
    script = """
    mkdir -p $rq || exit 1
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
    """
    code, out = _remote_shell_status(String(host), script)
    code == 0 || throw(ArgumentError("could not create run dir on $(host): $(strip(out))"))
    return src
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
    rid = run_id === nothing ? allocate_remote_run_id() : validate_run_id(run_id)
    src_logical = _posix_join(String(remote_root), "runs", rid, "src")
    warn_project_sshflags(canonical_local_path(local_root))
    _warn_ignored_local_preferences(canonical_local_path(local_root))
    packed = pack_ship_tar(
        local_root;
        allow_external_symlinks = allow_external_symlinks,
        ship_max_bytes = ship_max_bytes,
    )
    try
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
        rec = Dict{String, Any}(
            "algorithm" => "git-sha1",
            "content_tree_hash" => packed.hash,
            "bytes" => packed.bytes,
            "files" => packed.files,
            "run_id" => rid,
            "src" => src_logical,
            "host" => _record_host_alias(first(hosts)),
            "run_dir_empty_at_start" => true,
        )
        allow_external_symlinks && (rec["external_symlinks_allowed"] = true)
        packed.tree_matches_head && (rec["tree_matches_head"] = true)
        if any(hr -> hr.ok, host_results)
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
    exe = try
        _host_tool_exe("rsync")
    catch
        return nothing
    end
    ver = try
        lowercase(read(`$exe --version`, String))
    catch
        return nothing
    end
    occursin("openrsync", ver) || return nothing
    _OPENRSYNC_WARNED[] = true
    @warn "rsync on PATH is openrsync; collect / cache pull uses it, not GNU rsync"
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
