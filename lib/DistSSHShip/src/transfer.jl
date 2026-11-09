# Verified copy of a snapshot onto a caller-chosen remote directory.
# No run id, no run.toml, no instantiate, and no deletion of `dest`.
# A failed host can leave a partial tree. The caller must not treat that
# dest as a successful stage.

"""One host row from [`transfer_tree`](@ref)."""
struct TransferHostResult
    host::String
    ok::Bool
    message::String
end

"""
Result of [`transfer_tree`](@ref).

`dest` is the remote directory the tar was extracted into (the ship anchor).
`project_rel` is the project directory inside `dest` (`.` when the tar root
is the project). `ok` is false when any host failed. Nothing is deleted.
"""
struct TransferResult
    dest::String
    project_rel::String
    content_tree_hash::String
    algorithm::String
    bytes::Int
    files::Int
    hosts::Vector{TransferHostResult}
    ok::Bool
end

function _remote_stdlib_julia(julia_bin::AbstractString, expr::AbstractString, args::Vector{String})::String
    jb = DistSSHBase._remote_julia_path_sh(julia_bin)
    parts = String[
        jb,
        "--startup-file=no",
        "--compiled-modules=existing",
        "-e",
        DistSSHBase.posix_quote(expr),
    ]
    if !isempty(args)
        push!(parts, "--")
        append!(parts, args)
    end
    inner = join(parts, " ")
    return "(unset JULIA_PROJECT; JULIA_DEPOT_PATH= JULIA_LOAD_PATH=@stdlib exec $(inner))"
end

"""
Extract `tar_path` into remote `dest`, then walk symlinks and check the hash.

`dest` is not removed on failure. An escaping symlink is an error unless
`allow_external_symlinks` is set.
"""
function extract_verified!(
        host::AbstractString,
        dest::AbstractString,
        tar_path::AbstractString,
        julia_bin::AbstractString;
        allow_external_symlinks::Bool = false,
        expect_hash::AbstractString,
    )
    sq = DistSSHBase._remote_shell_path_word(dest)
    allow = allow_external_symlinks ? "1" : "0"
    inner = _remote_stdlib_julia(
        julia_bin,
        remote_extract_expr(),
        String[sq, DistSSHBase.posix_quote(allow), DistSSHBase.posix_quote(String(expect_hash))],
    )
    # ARGS are passed as shell words. posix_quote of "0"/"1" and the hash is
    # already quoted. `_remote_stdlib_julia` posix-quotes the expression and
    # appends args unquoted, so quote them here.
    err_buf = IOBuffer()
    out_buf = IOBuffer()
    cmd = DistSSHBase._host_sync_remote_shell_cmd(String(host), inner; forward_stdin = true)
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
        throw(
            ArgumentError(
                DistSSHBase.summarize_ssh_error(
                    Base.ProcessFailedException(Base.Process[proc]); stderr = err,
                )
            )
        )
    end
    code == 0 || DistSSHBase._throw_if_nonposix_shell(String(host), code, err)
    code == 0 || throw(ArgumentError("tar extract failed on $(host): $(strip(err) * strip(out))"))
    return nothing
end

function _prepare_dest_script(dest::AbstractString)::String
    q = DistSSHBase._remote_shell_path_word(dest)
    parent = dirname(rstrip(String(dest), '/'))
    pq = DistSSHBase._remote_shell_path_word(parent)
    return """
    if [ -L $q ]; then
      printf 'dest is a symlink: %s\\n' $q >&2
      exit 2
    fi
    if [ -e $q ] && [ ! -d $q ]; then
      printf 'dest exists and is not a directory: %s\\n' $q >&2
      exit 2
    fi
    if [ -d $q ]; then
      if [ -n "\$(ls -A $q 2>/dev/null)" ]; then
        printf 'dest is not empty: %s\\n' $q >&2
        exit 3
      fi
    else
      if [ ! -d $pq ]; then
        printf 'dest parent does not exist: %s\\n' $pq >&2
        exit 2
      fi
      mkdir $q || exit 1
    fi
    """
end

"""
    transfer_tree(snapshot, hosts, dest; allow_external_symlinks=false, julia=nothing) -> TransferResult

Extract `snapshot` into `dest` on each SSH host and verify the tree hash.

`dest` is the ship anchor (the project directory when there is no path
dependency outside it). `TransferResult.project_rel` is the project inside
that directory. This does not allocate a run id, write Run `run.toml`,
instantiate, or delete `dest`. A non-empty `dest` is an error and is left
in place. A failed extract can leave a partial tree.

When `write_record=true` (default), writes
`<dest>/.distssh/shipped.toml` with `complete = true` only after hash
verification succeeds. There is no in-flight marker: a missing or
incomplete record means the tree is not usable.
"""
function transfer_tree(
        snapshot::ShipSnapshot,
        hosts::AbstractVector{<:AbstractString},
        dest::AbstractString;
        allow_external_symlinks::Bool = false,
        julia::Union{Nothing, AbstractString} = nothing,
        write_record::Bool = true,
    )::TransferResult
    host_list = String[String(h) for h in hosts]
    isempty(host_list) && throw(ArgumentError("transfer_tree: no hosts"))
    length(unique(host_list)) == length(host_list) ||
        throw(ArgumentError("transfer_tree: hosts must be unique"))
    raw = strip(String(dest))
    (startswith(raw, "/") || startswith(raw, "~")) || throw(
        ArgumentError(
            "transfer_tree dest must be absolute or start with ~, got $(repr(raw))",
        )
    )
    checked = DistSSHBase._checked_remote_dest(raw)
    isfile(snapshot.tar_path) || throw(ArgumentError("transfer_tree: snapshot tar is missing"))
    got = String(Tar.tree_hash(snapshot.tar_path; algorithm = TREE_HASH_ALGORITHM, skip_empty = true))
    got == snapshot.content_tree_hash || throw(
        ArgumentError(
            "transfer_tree: tar content_tree_hash $(got) does not match snapshot $(snapshot.content_tree_hash)",
        )
    )
    rows = TransferHostResult[]
    for host in host_list
        DistSSHBase.validate_ssh_host(host)
        try
            code, out = DistSSHBase._remote_shell_status(host, _prepare_dest_script(checked))
            code == 0 || throw(ArgumentError("could not prepare dest on $(host): $(strip(out))"))
            pinned = DistSSHBase.resolve_remote_julia(host, julia)
            pinned === nothing && throw(ArgumentError("Julia not found on $host"))
            extract_verified!(
                host, checked, snapshot.tar_path, pinned;
                allow_external_symlinks = allow_external_symlinks,
                expect_hash = snapshot.content_tree_hash,
            )
            write_record && _write_complete_record!(host, checked, snapshot)
            push!(rows, TransferHostResult(host, true, "transfer ok"))
        catch e
            e isa InterruptException && rethrow()
            push!(rows, TransferHostResult(host, false, sprint(showerror, e)))
        end
    end
    ok = all(row -> row.ok, rows)
    return TransferResult(
        checked,
        snapshot.project_rel,
        snapshot.content_tree_hash,
        TREE_HASH_ALGORITHM,
        snapshot.bytes,
        snapshot.files,
        rows,
        ok,
    )
end
