# SSH, where Julia is, and remote paths.

# SSH configuration

# Default SSH `ConnectTimeout` seconds. Callers pass this into
# `wait_seconds`; it is not read from the environment here.
const _SSH_CONNECT_TIMEOUT_S = 10

# Whole seconds for an OpenSSH option. Non-positive stays `default`. A
# positive value is at least 1.
function _ssh_whole_seconds(name::Symbol, default::Int)::Int
    seconds = wait_seconds(name, default)
    seconds > 0 || return default
    return max(1, round(Int, seconds))
end

"""Build SSH options. `request_tty=false` (default) adds `RequestTTY=no`."""
function build_ssh_opts(; request_tty::Bool = false)
    custom = strip(get(ENV, "DISTRIBUTED_SSH_OPTS", ""))
    if isempty(custom)
        opts = String["-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes"]
        if !request_tty
            push!(opts, "-o", "RequestTTY=no")
        end
        connect = _ssh_whole_seconds(:ssh_connect, _SSH_CONNECT_TIMEOUT_S)
        # Ten probes. The gap is the silent budget divided across them, so the
        # default stays Interval=60 and CountMax=10 (about 600s).
        alive_count = 10
        silent = _ssh_whole_seconds(:peer_silent, 600)
        alive_interval = max(1, round(Int, silent / alive_count))
        append!(
            opts, (
                "-o", "ConnectTimeout=$connect",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ServerAliveInterval=$alive_interval",
                "-o", "ServerAliveCountMax=$alive_count",
                "-o", "TCPKeepAlive=yes",
            )
        )
        return opts
    end
    return _split_ssh_opts(custom)
end

"""Split `DISTRIBUTED_SSH_OPTS` with shell quoting. Unmatched quotes throw `ArgumentError`."""
function _split_ssh_opts(custom::AbstractString)::Vector{String}
    try
        return String[String(x) for x in Base.shell_split(custom)]
    catch e
        e isa ErrorException || rethrow()
        throw(ArgumentError("DISTRIBUTED_SSH_OPTS: $(e.msg)"))
    end
end

"""
    ssh_opts(; request_tty=false) -> Vector{String}

SSH argv flags for `ssh` / `scp` / rsync `-e`.

Reads `DISTRIBUTED_SSH_OPTS` **live** (not frozen at package precompile). Prefer
this over a `const` so E2E / ProxyJump overrides apply in the same process.

A non-empty `DISTRIBUTED_SSH_OPTS` **replaces** the default vector (it is not
merged). It is split with `Base.shell_split`, so a quoted value that contains
spaces stays one argument. An unmatched quote throws `ArgumentError`.
`request_tty` only changes the default vector: `false` includes
`-o RequestTTY=no`; `true` omits it so a caller may put `ssh -t` before or
after these flags. The ENV replacement is unchanged (if it contains
`RequestTTY=no`, put `-t` **after** the vector). Use `-o RequestTTY=no`,
not `ssh -T`: these flags are also passed to `scp` (`scp -T` is unrelated).
Does not insert `-t` (that flag is `ssh`-only).
"""
function ssh_opts(; request_tty::Bool = false)::Vector{String}
    return String[String(x) for x in build_ssh_opts(; request_tty = request_tty)]
end

"""`ssh` / `rsync` / `git` on `PATH`, or throw `ArgumentError`."""
function _host_tool_exe(name::AbstractString)::String
    n = _normalize_host_tool(name)
    exe = Sys.which(n)
    exe === nothing && throw(ArgumentError(explain_host_tool_missing(n)))
    return exe
end

_host_tool_present(name::AbstractString)::Bool = Sys.which(_normalize_host_tool(name)) !== nothing

_rethrow_missing_host_tool(e) = e isa ArgumentError && rethrow(e)

"""`ssh` on `PATH`, or throw `ArgumentError`."""
_ssh_exe()::String = _host_tool_exe("ssh")

function _host_tool_cmd(name::AbstractString, args::AbstractVector)::Cmd
    return Cmd(append!([_host_tool_exe(name)], String[String(a) for a in args]))
end

_git_cmd(args::AbstractVector)::Cmd = _host_tool_cmd("git", args)
_ssh_cmd(args::AbstractVector)::Cmd = _host_tool_cmd("ssh", args)

"""`--` then `host`, then `args`. A name that starts with `-` is rejected."""
function _ssh_host_args(host::AbstractString, args::AbstractString...)::Vector{String}
    dest = validate_ssh_host(host)
    return String["--", dest, String.(args)...]
end
_scp_cmd(args::AbstractVector)::Cmd = _host_tool_cmd("scp", args)

"""
Effective SSH `User` for `host` from `ssh -G` (config / defaults).

Returns `nothing` when the query fails. Used so [`ssh_addprocs_machine`](@ref)
can pass `user@host` into `Distributed.addprocs` (which otherwise prefixes the
local `\$USER` and overrides SSH config `User`).
"""
function ssh_config_user(host::AbstractString)::Union{Nothing, String}
    h = String(strip(host))
    isempty(h) && return nothing
    try
        # -n: no stdin; -G dumps effective config (User, HostName, …).
        out = read(_ssh_cmd(["-n", ssh_opts()..., "-G", _ssh_host_args(h)...]), String)
        for line in eachsplit(out, '\n'; keepempty = false)
            if startswith(line, "user ")
                u = strip(SubString(line, 6))
                return isempty(u) ? nothing : String(u)
            end
        end
    catch
    end
    return nothing
end

"""
Machine string for `Distributed.addprocs` over SSH.

If `host` already contains `@`, it is returned unchanged. Otherwise the effective
SSH config user (via [`ssh_config_user`](@ref)) is prefixed so tunneling does not
authenticate as the local login name.

# Examples
```jldoctest
julia> using DistSSHRun

julia> DistSSHRun.ssh_addprocs_machine("dev@host1")
"dev@host1"
```
"""
function ssh_addprocs_machine(host::AbstractString)::String
    h = String(strip(host))
    isempty(h) && return h
    h = validate_ssh_host(h)
    occursin('@', h) && return h
    u = ssh_config_user(h)
    return u === nothing ? h : string(u, '@', h)
end

"""Parse `julia --version` output (e.g. `"julia version 1.13.1"`) into a `VersionNumber`.
Returns `nothing` if the text doesn't match the expected pattern.

# Examples
```jldoctest
julia> using DistSSHRun

julia> DistSSHRun.DistSSHBase.parse_julia_version("julia version 1.13.1")
v"1.13.1"

julia> DistSSHRun.DistSSHBase.parse_julia_version("not julia") === nothing
true
```
"""
function parse_julia_version(version_output::AbstractString)::Union{Nothing, VersionNumber}
    m = match(r"julia version (\d+\.\d+\.\d+)", String(version_output))
    m === nothing && return nothing
    cap = m.captures[1]
    cap isa AbstractString || return nothing
    try
        return VersionNumber(String(cap))
    catch
        return nothing
    end
end

"""One remote argument: quoted `julia_path`, then `--version`.

OpenSSH joins every word after the host into one `\$SHELL -c` string. A path
with spaces must not be its own SSH argument. See [`_remote_julia_path_sh`](@ref).
"""
function _remote_julia_version_remote_command(julia_path::AbstractString)::String
    return string(_remote_julia_path_sh(julia_path), " --version")
end

"""Stdout of `julia_path --version` on `host`."""
function _remote_julia_version_output(host::String, julia_path::AbstractString)::String
    remote = _remote_julia_version_remote_command(julia_path)
    return read(
        pipeline(
            _ssh_cmd([ssh_opts()..., _ssh_host_args(host, remote)...]);
            stderr = devnull,
        ),
        String,
    )
end

"""Get the Julia version on a remote host by running `julia_path --version` over SSH.
Returns `nothing` on any failure (SSH, missing binary, unparseable output)."""
function get_remote_julia_version(host::String, julia_path::AbstractString)::Union{Nothing, VersionNumber}
    try
        return parse_julia_version(_remote_julia_version_output(host, julia_path))
    catch
        return nothing
    end
end

include("version_parse.jl")

"""
Ordered remote Julia path candidates for `uname -s` output (Darwin vs Linux).

Prefers juliaup (`\$HOME/.juliaup/bin/julia`), then platform paths. Homebrew
only on Darwin. Callers still verify with `test -x` and `--version` before
accepting a hit.
"""
function remote_julia_candidates(uname_s::AbstractString)::Vector{String}
    os = lowercase(strip(String(uname_s)))
    juliaup = raw"$HOME/.juliaup/bin/julia"
    if startswith(os, "darwin")
        return String[juliaup, "/opt/homebrew/bin/julia", "/usr/local/bin/julia", "/usr/bin/julia"]
    end
    return String[juliaup, "/usr/bin/julia", "/usr/local/bin/julia"]
end

"""Whether `path` looks like an auto-detect request (`nothing` / empty / `auto`)."""
_julia_spec_is_auto(::Nothing)::Bool = true
function _julia_spec_is_auto(spec::AbstractString)::Bool
    s = strip(String(spec))
    return isempty(s) || lowercase(s) == "auto"
end

"""
Resolve the Julia binary on this kit parent (`nothing` / `"auto"` / empty →
the running process). Explicit paths are kept as given after usability check.

Throws `ArgumentError` when the binary is missing or `--version` does not parse.
"""
function resolve_controller_julia(spec::Union{Nothing, AbstractString} = nothing)::String
    path = if _julia_spec_is_auto(spec)
        String(something(Base.julia_cmd().exec[1], ""))
    else
        String(strip(String(spec::AbstractString)))
    end
    isempty(path) && throw(ArgumentError("Julia binary not resolved on the kit parent"))
    abs = isabspath(path) ? path : abspath(path)
    try
        out = read(pipeline(Cmd([abs, "--version"]); stderr = devnull), String)
        parse_julia_version(out) === nothing && throw(
            ArgumentError(
                "kit parent Julia at $(abs) did not report a parseable --version",
            )
        )
    catch e
        e isa ArgumentError && rethrow()
        throw(ArgumentError("kit parent Julia not usable at $(abs): $(sprint(showerror, e))"))
    end
    return abs
end

"""
Resolve Julia on SSH `host`.

`nothing` / `"auto"` / empty → `detect_julia_path`. Explicit path must
pass remote `--version`. Returns `nothing` when auto-detect fails (no bare
`"julia"` fallback).
"""
function resolve_remote_julia(
        host::AbstractString,
        spec::Union{Nothing, AbstractString} = nothing,
    )::Union{Nothing, String}
    h = String(host)
    if _julia_spec_is_auto(spec)
        return detect_julia_path(h)
    end
    path = String(strip(String(spec::AbstractString)))
    isempty(path) && return nothing
    get_remote_julia_version(h, path) === nothing && return nothing
    return path
end

"""Escape `\\`, `"`, `` ` ``, and `\$` inside a POSIX double-quoted word."""
function _remote_dq_escape(s::AbstractString)::String
    return sprint() do io
        for c in String(s)
            if c == '\\' || c == '"' || c == '`' || c == '$'
                print(io, '\\')
            end
            print(io, c)
        end
    end
end

"""
One remote-shell word for a Julia binary path.

A leading `~/` is rewritten to `\$HOME/` so `~/julia-1.x/bin/julia` still
expands. A `\$HOME` prefix is double-quoted (the prefix itself still expands).
A backtick, double quote, backslash, or any other `\$` in that word is escaped.
Every other path is POSIX single-quoted.
"""
function _remote_julia_path_sh(path::AbstractString)::String
    _reject_control_path(path)
    s = String(path)
    if startswith(s, "~/")
        s = string("\$HOME", chopprefix(s, "~"))
    end
    prefix = "\$HOME"
    if startswith(s, prefix)
        return string('"', prefix, _remote_dq_escape(chopprefix(s, prefix)), '"')
    end
    return posix_quote(s)
end

function _remote_julia_candidates_sh(uname_s::AbstractString)::String
    return sprint() do io
        first = true
        for p in remote_julia_candidates(uname_s)
            first || print(io, ' ')
            first = false
            print(io, _remote_julia_path_sh(p))
        end
    end
end

"""
    posix_quote(word::AbstractString) -> String

One POSIX single-quoted word for a remote `sh` command.

A `'` inside `word` becomes `'\\''`. Every other byte is copied, including
newline. NUL throws `ArgumentError` (a remote process cannot carry it).
A path goes through [`_remote_shell_path_word`](@ref), which rejects a control
character. A host goes through [`validate_ssh_host`](@ref), which rejects a
name that starts with `-` and a control character.
"""
function posix_quote(word::AbstractString)::String
    s = String(word)
    if occursin('\0', s)
        throw(ArgumentError("posix_quote: word contains NUL. See help setup."))
    end
    return sprint() do io
        print(io, '\'')
        for c in s
            if c == '\''
                print(io, "'\\''")
            else
                print(io, c)
            end
        end
        print(io, '\'')
    end
end

"""[`posix_quote`](@ref). Callers use `posix_quote`."""
function _remote_sh_quote(word::AbstractString)::String
    return posix_quote(word)
end

"""Throw when `path` contains a control character (NUL, newline, or any other)."""
function _reject_control_path(path::AbstractString)::Nothing
    s = String(path)
    any(iscntrl, s) || return nothing
    throw(
        ArgumentError(
            "path contains a newline or NUL ($(repr(s))). See help setup.",
        ),
    )
end

function _remote_argv_sh(argv::AbstractVector{<:AbstractString})::String
    return sprint() do io
        first = true
        for a in argv
            first || print(io, ' ')
            first = false
            print(io, posix_quote(a))
        end
    end
end

"""Remote `sh -c` body: find Julia (same candidates as detect) then `exec` it with `argv`."""
function _run_on_host_remote_sh(
        argv::AbstractVector{<:AbstractString};
        julia::Union{Nothing, AbstractString} = nothing,
        detect::Bool = true,
    )::String
    extra = _remote_argv_sh(argv)
    spec = julia
    use_detect = detect && _julia_spec_is_auto(spec)
    if use_detect
        darwin_set = sprint() do io
            print(io, "set -- ")
            print(io, _remote_julia_candidates_sh("Darwin"))
        end
        linux_set = sprint() do io
            print(io, "set -- ")
            print(io, _remote_julia_candidates_sh("Linux"))
        end
        return sprint() do io
            print(io, "u=\$(uname -s); case \"\$u\" in Darwin*) ")
            print(io, darwin_set)
            print(io, " ;; *) ")
            print(io, linux_set)
            print(io, " ;; esac; JULIA=; for p in \"\$@\"; do if [ -x \"\$p\" ] && \"\$p\" --version 2>/dev/null | grep -q 'julia version'; then JULIA=\$p; break; fi; done; ")
            print(io, "if [ -z \"\$JULIA\" ]; then JULIA=\$(command -v julia 2>/dev/null || true); fi; ")
            print(io, "[ -n \"\$JULIA\" ] && [ -x \"\$JULIA\" ] && \"\$JULIA\" --version 2>/dev/null | grep -q 'julia version' || exit 127; exec \"\$JULIA\"")
            isempty(extra) || (print(io, ' '); print(io, extra))
        end
    end
    path = spec === nothing ? "" : String(strip(String(spec)))
    isempty(path) && throw(
        ArgumentError(
            "run_on_host: detect=false requires julia= to a remote path (not auto)",
        )
    )
    _reject_control_path(path)
    q = posix_quote(path)
    return sprint() do io
        print(io, "JULIA="); print(io, q)
        print(io, "; [ -x \"\$JULIA\" ] && \"\$JULIA\" --version 2>/dev/null | grep -q 'julia version' || exit 127; exec \"\$JULIA\"")
        isempty(extra) || (print(io, ' '); print(io, extra))
    end
end

"""
    run_on_host(host, argv; julia=nothing, detect=true, tty=false, wait=true) -> Base.Process

One SSH connection: resolve remote Julia the same way as
`resolve_remote_julia` / `detect_julia_path`, then `exec` it
with `argv` (Julia flags / script / args). Does not replace
`resolve_remote_julia` when the caller only needs the path.

`julia=nothing` / `"auto"` with `detect=true` probes candidates on the remote.
`detect=false` requires an explicit path. `tty=true` adds `ssh -t`.
Process-local detect cache is not used (a new CLI process never hits it).

SSH is `ignorestatus`: a non-zero remote or ssh exit returns the `Process`
(`.exitcode`) instead of throwing `ProcessFailedException`. Missing `ssh` on
`PATH` throws `ArgumentError`.
"""
function run_on_host(
        host::AbstractString,
        argv::AbstractVector{<:AbstractString} = String[];
        julia::Union{Nothing, AbstractString} = nothing,
        detect::Bool = true,
        tty::Bool = false,
        wait::Bool = true,
    )::Base.Process
    h = String(strip(host))
    isempty(h) && throw(ArgumentError("run_on_host: host must be non-empty"))
    inner = _run_on_host_remote_sh(argv; julia = julia, detect = detect)
    args = String[ssh_opts(; request_tty = tty)...]
    tty && push!(args, "-t")
    append!(args, _ssh_host_args(h, inner))
    return run(ignorestatus(_ssh_cmd(args)); wait = wait)
end

# Process-local auto-detect results (`nothing` included). Same host in
# `size!` then `drive!` / `--check` then `--instantiate` skips repeat SSH.
const _DETECT_JULIA_PATH_CACHE = Dict{String, Union{Nothing, String}}()

"""Drop cached `detect_julia_path` results (`host=nothing` → all hosts)."""
function clear_detect_julia_path_cache!(host::Union{Nothing, AbstractString} = nothing)
    if host === nothing
        empty!(_DETECT_JULIA_PATH_CACHE)
    else
        delete!(_DETECT_JULIA_PATH_CACHE, String(strip(host)))
    end
    return nothing
end

"""Run `script` on `host`. Returns `(exitcode, stdout)`.

SSH's own failure (exit 255) throws `ArgumentError` from [`summarize_ssh_error`](@ref).
A non-POSIX login shell throws `ArgumentError` and points to `help setup`.
Other non-zero exits are returned so a missing command can stay `nothing`.
"""
function _remote_shell_status(host::String, script::AbstractString)::Tuple{Int, String}
    err_buf = IOBuffer()
    out_buf = IOBuffer()
    cmd = _host_sync_remote_shell_cmd(host, script)
    proc = try
        run(pipeline(ignorestatus(cmd); stdout = out_buf, stderr = err_buf); wait = true)
    catch e
        _rethrow_missing_host_tool(e)
        rethrow()
    end
    code = Int(something(proc.exitcode, 1))
    out = String(take!(out_buf))
    err = String(take!(err_buf))
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
    code == 0 || _throw_if_nonposix_shell(host, code, err)
    return code, out
end

"""Detect Julia path on remote host via SSH (executable + parseable `--version`).

Returns `nothing` when the remote shell ran and no Julia was found. That result
is cached. SSH transport failure (exit 255) throws `ArgumentError` and is not
cached. A failed command whose login shell is non-POSIX also throws
`ArgumentError` (see `help setup`) and is not cached.
"""
function detect_julia_path(host::String)::Union{Nothing, String}
    h = String(strip(host))
    isempty(h) && return nothing
    if haskey(_DETECT_JULIA_PATH_CACHE, h)
        return _DETECT_JULIA_PATH_CACHE[h]
    end
    found = _detect_julia_path_uncached(h)
    _DETECT_JULIA_PATH_CACHE[h] = found
    return found
end

"""`--version` over the setup SSH transport (honors `DISTSSHKIT_TEST_SSH`)."""
function _remote_julia_reports_version(host::String, path::AbstractString)::Bool
    pq = _remote_shell_path_word(String(path))
    try
        out = read(
            pipeline(_host_sync_remote_shell_cmd(host, "$pq --version"); stderr = devnull),
            String,
        )
        return parse_julia_version(out) !== nothing
    catch e
        _throw_if_nonposix_shell(host, e)
        return false
    end
end

function _detect_julia_path_uncached(host::String)::Union{Nothing, String}
    code, out = _remote_shell_status(host, "uname -s")
    uname_s = code == 0 ? strip(out) : ""

    if !isempty(uname_s)
        for path in remote_julia_candidates(uname_s)
            try
                result = read(
                    pipeline(
                        _host_sync_remote_shell_cmd(host, "test -x $path && echo $path");
                        stderr = devnull,
                    ), String
                )
                found = strip(result)
                isempty(found) && continue
                _remote_julia_reports_version(host, found) || continue
                return String(found)
            catch e
                _rethrow_missing_host_tool(e)
                _throw_if_nonposix_shell(host, e)
                continue
            end
        end
    end
    code, out = _remote_shell_status(host, "command -v julia || which julia")
    code == 0 || return nothing
    p = strip(out)
    isempty(p) && return nothing
    _remote_julia_reports_version(host, p) || return nothing
    return String(p)
end


function _remote_tilde_prefix_bare(prefix::AbstractString)::Bool
    return occursin(r"^~[A-Za-z0-9._-]*$", prefix)
end

"""
Shell word for `path` on the remote login shell.

A `~` / `~user` prefix stays unquoted so the remote shell expands it, when the
prefix is only `~` and letters, digits, `.`, `_`, or `-`. The rest of a `~/…`
path is passed through [`posix_quote`](@ref). Other paths are quoted in full.
A control character in `path` is rejected.
"""
function _remote_shell_path_word(path::AbstractString)::String
    _reject_control_path(path)
    p = strip(String(path))
    startswith(p, "~") || return posix_quote(p)
    slash = findfirst('/', p)
    if slash === nothing
        return _remote_tilde_prefix_bare(p) ? p : posix_quote(p)
    end
    prefix = p[1:(slash - 1)]
    rest = p[(slash + 1):end]
    _remote_tilde_prefix_bare(prefix) || return posix_quote(p)
    isempty(rest) && return prefix * "/"
    return prefix * "/" * posix_quote(rest)
end

"""
Build a remote shell snippet that resolves `remote_path` to an absolute path.

Works for directories and regular files (`cd` alone fails on file paths).
A `~/…` layout that does not exist yet still expands `~` (`printf`); collect
then `mkdir -p`. Other missing paths still fail.
"""
function _remote_abs_path_resolve_shell(remote_path::AbstractString)::String
    path = strip(String(remote_path))
    pq = _remote_shell_path_word(path)
    exist = "if test -d $pq; then cd $pq && pwd; elif test -e $pq; then d=\$(dirname $pq) && b=\$(basename $pq) && cd \"\$d\" && echo \"\$(pwd)/\$b\"; else exit 1; fi"
    startswith(path, "~") || return exist
    return "if test -d $pq; then cd $pq && pwd; elif test -e $pq; then d=\$(dirname $pq) && b=\$(basename $pq) && cd \"\$d\" && echo \"\$(pwd)/\$b\"; else printf '%s\\n' $pq; fi"
end

"""
Map `local_abs` under `local_repo_root` to an absolute path on `host`.

For `parent`, returns the canonical local path. For SSH hosts, uses
[`remote_layout_path`](@ref) then [`resolve_remote_abs_path_on_host`](@ref).
Returns `nothing` when the remote path cannot be resolved.
"""
function resolve_host_path_abs(
        host::AbstractString,
        local_abs::AbstractString,
        local_repo_root::AbstractString,
    )::Union{Nothing, String}
    path_local = canonical_local_path(local_abs)
    h = String(strip(host))
    is_parent_host_name(h) && return path_local
    mapped = remote_layout_path(path_local, local_repo_root)
    return resolve_remote_abs_path_on_host(h, mapped)
end

"""
Absolute project root for `addprocs` / size probe on `host`.

Equivalent to [`resolve_host_path_abs`](@ref)`(host, local_project, local_project)`.
"""
function resolve_host_project_abs(
        host::AbstractString,
        local_project::AbstractString,
    )::Union{Nothing, String}
    return resolve_host_path_abs(host, local_project, local_project)
end

"""
Resolve `remote_path` to an absolute path on `host` via SSH (`cd … && pwd`).

Returns `remote_path` unchanged when it is already absolute (`/` prefix).
A `~/…` layout is expanded on the host even if the tree is not created yet.
Returns `nothing` when SSH fails, or when a non-tilde path does not exist.
A non-POSIX login shell throws `ArgumentError` (see `help setup`).
"""
function resolve_remote_abs_path_on_host(host::String, remote_path::AbstractString)::Union{Nothing, String}
    path = strip(String(remote_path))
    isempty(path) && return nothing
    _reject_control_path(path)
    startswith(path, "/") && return path
    try
        inner = _remote_abs_path_resolve_shell(path)
        s = strip(read(pipeline(_ssh_cmd([ssh_opts()..., _ssh_host_args(host, inner)...]); stderr = devnull), String))
        isempty(s) && return nothing
        return String(s)
    catch e
        _throw_if_nonposix_shell(host, e)
        return nothing
    end
end

"""Remote login-shell snippet for [`get_remote_git_hash`](@ref)."""
function _remote_git_hash_inner(
        remote_repo_dir::AbstractString;
        short::Union{Nothing, Int} = nothing,
    )::String
    dir = strip(String(remote_repo_dir))
    pq = _remote_shell_path_word(dir)
    rev = short === nothing ? "HEAD" : "--short=$(short) HEAD"
    return if startswith(dir, "~")
        "cd $pq && git rev-parse $rev"
    else
        "git -C $pq rev-parse $rev"
    end
end

"""
Get remote git commit hash via SSH.

`remote_repo_dir` starting with `~` uses `cd DIR && git rev-parse …` (shell expands `~`);
otherwise uses `git -C DIR rev-parse …` (absolute path on the remote, same layout as local).
A non-POSIX login shell throws `ArgumentError` (see `help setup`).
"""
function get_remote_git_hash(host::String, remote_repo_dir::AbstractString; short::Union{Nothing, Int} = nothing)::Union{Nothing, String}
    try
        inner = _remote_git_hash_inner(remote_repo_dir; short = short)
        s = strip(read(pipeline(_ssh_cmd([ssh_opts()..., _ssh_host_args(host, inner)...]); stderr = devnull), String))
        return isempty(s) ? nothing : s
    catch e
        _throw_if_nonposix_shell(host, e)
        return nothing
    end
end

# Remote resource detection

"""Get total memory (GB) for a remote host via SSH."""
function get_remote_total_gb(host::String)
    try
        s = strip(
            read(
                pipeline(
                    _ssh_cmd(
                        [
                            ssh_opts()..., _ssh_host_args(host)...,
                            "sysctl -n hw.memsize 2>/dev/null || awk '/MemTotal/{print \$2*1024}' /proc/meminfo 2>/dev/null",
                        ]
                    );
                    stderr = devnull
                ), String
            )
        )
        isempty(s) && return nothing
        return parse(Float64, s) / 1024^3
    catch e
        _throw_if_nonposix_shell(host, e)
    end
    return nothing
end

"""Get CPU core count for a remote host via SSH."""
function get_remote_nproc(host::String)
    try
        s = strip(
            read(
                pipeline(
                    _ssh_cmd(
                        [
                            ssh_opts()..., _ssh_host_args(host)...,
                            "sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null",
                        ]
                    ); stderr = devnull
                ), String
            )
        )
        isempty(s) && return nothing
        return parse(Int, s)
    catch e
        _throw_if_nonposix_shell(host, e)
    end
    return nothing
end

"""
Absolute path for `remote_path` on `host` — the kit-parent/remote path boundary.

Use this before any kit-parent-side join, compare, `relpath`, or rsync URI that
involves a remote path. Already-absolute paths (`/` prefix) are returned
unchanged. Paths starting with `~` are resolved **on the remote** via
[`resolve_remote_abs_path_on_host`](@ref). Returns `nothing` when resolution fails.

`~` may still be passed unquoted to remote shells (`_remote_shell_path_word`);
do not feed tilde strings into Julia's `expanduser` / `relpath` / `abspath`.
"""
function ensure_remote_abs_path(
        host::AbstractString,
        remote_path::AbstractString,
    )::Union{Nothing, String}
    path = strip(String(remote_path))
    isempty(path) && return nothing
    startswith(path, "/") && return path
    return resolve_remote_abs_path_on_host(String(host), path)
end

"""
Map remote absolute path under `remote_repo` to the same repo-relative path under `local_repo`.

`remote_abs` and `remote_repo` must already be absolute (`/` prefix). Pass
[`ensure_remote_abs_path`](@ref) results — never `~/…` (kit parent `abspath` would
expand tilde to the **local** home).
"""
function local_dir_from_remote_mirror(
        remote_abs::AbstractString,
        remote_repo::AbstractString,
        local_repo::AbstractString,
    )::String
    ra = String(strip(String(remote_abs)))
    rr = String(strip(String(remote_repo)))
    if !(startswith(ra, "/") && startswith(rr, "/"))
        throw(
            ArgumentError(
                "local_dir_from_remote_mirror requires absolute remote paths; got $(repr(ra)) under $(repr(rr)). Expand ~ via ensure_remote_abs_path first.",
            )
        )
    end
    ra = String(abspath(ra))
    rr = String(abspath(rr))
    lr = String(abspath(local_repo))
    rel = String(relpath(ra, rr))
    startswith(rel, "..") &&
        throw(ArgumentError("remote path $(repr(ra)) is not under remote repo $(repr(rr))"))
    return String(abspath(joinpath(lr, rel)))
end

"""
Default remote layout used by `setup.jl` when paths are not overridden:
`~/basename(parent)/basename(local_project_root)` (tilde for remote-shell expansion).
"""
function default_remote_project_path(local_project_root::AbstractString)::String
    root = canonical_local_path(local_project_root)
    return joinpath("~", basename(dirname(root)), basename(root))
end

"""Remote tree root for `local_tree` (override, else `DISTRIBUTED_REMOTE_PROJECT_ROOT`, else the default layout)."""
function _remote_tree_root(
        local_tree::AbstractString;
        cli_override::Union{Nothing, AbstractString} = nothing,
    )::String
    if cli_override !== nothing
        s = strip(String(cli_override))
        if !isempty(s)
            _reject_control_path(s)
            return s
        end
    end
    env = strip(get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", ""))
    if !isempty(env)
        _reject_control_path(env)
        return env
    end
    root = default_remote_project_path(local_tree)
    _reject_control_path(root)
    return root
end

"""
Directory on the worker that receives `setup --ship-tree` of [`resolve_pkg_env`](@ref) `env_dir`.

An override (`--remote-path` / `DISTRIBUTED_REMOTE_PROJECT_ROOT`) is this tree
root, not the member directory.
"""
function remote_deploy_root(
        local_project_root::AbstractString;
        cli_override::Union{Nothing, AbstractString} = nothing,
    )::String
    env = resolve_pkg_env(local_project_root)
    return _remote_tree_root(env.env_dir; cli_override = cli_override)
end

"""
Worker `--project` path for `local_project_root`.

Same override rules as [`remote_deploy_root`](@ref). When the Manifest lives in
a parent of the member, this is `deploy_root` plus that relative path.
A single-project tree returns the deploy root unchanged. Does not `abspath`
tilde paths.
"""
function resolve_remote_project_root(
        local_project_root::AbstractString;
        cli_override::Union{Nothing, AbstractString} = nothing,
    )::String
    env = resolve_pkg_env(local_project_root)
    deploy = _remote_tree_root(env.env_dir; cli_override = cli_override)
    rel = julia_project_rel(env)
    return rel == "." ? deploy : _join_under_remote_root(deploy, rel)
end

"""
Directory `git clone` should create.

When the git work tree root is [`resolve_pkg_env`](@ref) `env_dir`, this is
[`remote_deploy_root`](@ref). When `env_dir` sits under that work tree, the
destination is the ancestor of the deploy root by the same relative path, so
the Manifest directory still lands on the deploy root. That ancestor is refused
when it is `~`, `/`, or a single directory under `/`. Pass `--remote-path` so
the git root stays below those. No git work tree keeps
[`resolve_remote_project_root`](@ref) (the member).
"""
function remote_git_clone_dest(
        local_project_root::AbstractString;
        cli_override::Union{Nothing, AbstractString} = nothing,
    )::String
    env = resolve_pkg_env(local_project_root)
    deploy = _remote_tree_root(env.env_dir; cli_override = cli_override)
    top = git_work_tree(env.project_dir)
    top isa String || return _checked_remote_dest(
        resolve_remote_project_root(local_project_root; cli_override = cli_override),
    )
    # `git rev-parse` may return `/private/var/...` while Julia's temp path is `/var/...`.
    env_root = canonical_local_path(realpath(env.env_dir))
    top_root = canonical_local_path(realpath(top))
    _path_is_under(env_root, top_root) || return _checked_remote_dest(
        resolve_remote_project_root(local_project_root; cli_override = cli_override),
    )
    rel = relpath(env_root, top_root)
    walked = _remote_ancestor_walk(deploy, rel)
    walked === nothing && return _remote_ancestor(deploy, rel)
    _remote_path_forbidden(walked) && throw(
        ArgumentError(
            "refusing to clone into $(repr(walked)); " *
                "pass --remote-path so the git root is not ~, /, or a single directory under /",
        ),
    )
    return _checked_remote_dest(walked)
end

"""
Path `setup --delete` removes.

When the git work tree contains `env_dir` and the deploy path ends with that
relative path, this is [`remote_git_clone_dest`](@ref), so a clone that landed
above the deploy root is removed with `.git`. An override that cannot express
that parent, or no git work tree, removes [`remote_deploy_root`](@ref).
A result of `~`, `~user`, `/`, a single directory under `/`, or this machine's
home is refused. A walk that would land there uses the deploy root instead,
unless that root is itself refused.
"""
function remote_delete_root(
        local_project_root::AbstractString;
        cli_override::Union{Nothing, AbstractString} = nothing,
    )::String
    env = resolve_pkg_env(local_project_root)
    deploy = _remote_tree_root(env.env_dir; cli_override = cli_override)
    top = git_work_tree(env.project_dir)
    top isa String || return _checked_remote_dest(deploy)
    env_root = canonical_local_path(realpath(env.env_dir))
    top_root = canonical_local_path(realpath(top))
    _path_is_under(env_root, top_root) || return _checked_remote_dest(deploy)
    mapped = _remote_ancestor_or_nothing(deploy, relpath(env_root, top_root))
    return _checked_remote_dest(mapped === nothing ? deploy : mapped)
end

"""True for `~`, `~user`, `/`, one directory under `/`, this machine's home, or a `.` or `..` component."""
function _remote_path_forbidden(path::AbstractString)::Bool
    p = strip(String(path))
    isempty(p) && return true
    p = rstrip(p, '/')
    isempty(p) && return true
    occursin(r"^~[^/]*$", p) && return true
    parts = split(p, '/'; keepempty = false)
    any(part -> part == "." || part == "..", parts) && return true
    if startswith(p, "/") && length(parts) <= 1
        return true
    end
    home = strip(homedir())
    return !isempty(home) && p == rstrip(home, '/')
end

"""Throw when [`_remote_path_forbidden`](@ref) is true. Returns `path` otherwise."""
function _checked_remote_dest(path::AbstractString)::String
    _remote_path_forbidden(path) || return String(path)
    throw(
        ArgumentError(
            "refusing remote path $(repr(strip(String(path)))); " *
                "it is ~, /, a single directory under /, this machine's home, or contains . or ..",
        )
    )
end

"""Drop `rel` from the end of a remote layout path. `rel` of `.` returns `remote_path`."""
function _remote_ancestor(remote_path::AbstractString, rel::AbstractString)::String
    mapped = _remote_ancestor_or_nothing(remote_path, rel)
    mapped === nothing && throw(
        ArgumentError(
            "Remote path $remote_path does not end with $rel, " *
                "so clone cannot keep the Manifest directory there. " *
                "Pass --remote-path for the remote path of the git root.",
        ),
    )
    return mapped
end

"""Walk `rel` off `remote_path`, including a result this package will not delete."""
function _remote_ancestor_walk(
        remote_path::AbstractString,
        rel::AbstractString,
    )::Union{Nothing, String}
    rel == "." && return String(remote_path)
    p = String(remote_path)
    for part in reverse(split(String(rel), '/'))
        (isempty(part) || part == ".") && continue
        part == ".." && return nothing
        basename(p) == part || return nothing
        parent = dirname(p)
        parent == p && return nothing
        p = parent
    end
    return p
end

"""`_remote_ancestor_walk`, or `nothing` when `rel` does not fit or the result is refused."""
function _remote_ancestor_or_nothing(
        remote_path::AbstractString,
        rel::AbstractString,
    )::Union{Nothing, String}
    p = _remote_ancestor_walk(remote_path, rel)
    p === nothing && return nothing
    return _remote_path_forbidden(p) ? nothing : p
end

"""Layout path for `DISTRIBUTED_REMOTE_PROJECT_ROOT` (kit parent ENV / `execute!`).

`~…` stays a remote-shell layout (do not `expanduser` on the kit parent).
Absolute paths are [`canonical_local_path`](@ref).
"""
function remote_env_project_root(raw::AbstractString)::String
    _reject_control_path(raw)
    s = strip(String(raw))
    isempty(s) && throw(ArgumentError("remote project root is empty"))
    startswith(s, "~") && return s
    return canonical_local_path(s)
end

"""Convert `https://github.com/...` clone URLs to SSH; leave other URLs unchanged.

# Examples
```jldoctest
julia> using DistSSHRun

julia> DistSSHRun.normalize_git_clone_url("https://github.com/org/App.jl.git")
"git@github.com:org/App.jl.git"
```
"""
function normalize_git_clone_url(url::AbstractString)::String
    origin_url = strip(String(url))
    m = match(r"https://github\.com/(.+)", origin_url)
    if m !== nothing
        cap = m.captures[1]
        return cap isa AbstractString ? ("git@github.com:" * String(cap)) : origin_url
    end
    return origin_url
end

"""Read `origin` from `proj_dir` and return a clone URL (HTTPS GitHub → SSH). `nothing` on failure."""
function clone_url_from_local_origin(proj_dir::AbstractString)::Union{Nothing, String}
    _host_tool_present("git") || return nothing
    resolved = canonical_local_path(proj_dir)
    try
        origin_url = strip(
            read(
                pipeline(
                    _git_cmd(["-C", resolved, "remote", "get-url", "origin"]);
                    stderr = devnull
                ), String
            )
        )
        isempty(origin_url) && return nothing
        return normalize_git_clone_url(origin_url)
    catch
        return nothing
    end
end

"""Join `rel` under remote repo root without expanding `~` on the local machine."""
function _join_under_remote_root(rroot::String, rel::String)::String
    if isempty(rel) || rel == "."
        return rroot
    end
    out = joinpath(rroot, rel)
    startswith(rroot, "~") && return String(out)
    return String(abspath(out))
end

"""
    remote_layout_path(local_abs_dir, local_application_repo_root) -> String

Layout path, not a path resolved on the host. It may start with `~`.
Do not `expanduser` it on this machine. Pass it through
[`ensure_remote_abs_path`](@ref) before using it on a host.

A path outside `local_application_repo_root` is returned unchanged.
That result is the local absolute path, not a remote path.

A path under the repo root is the same relative path under
[`resolve_remote_project_root`](@ref). The default root matches
`setup --clone` (`~/Parent/RepoName`). Override with
`DISTRIBUTED_REMOTE_PROJECT_ROOT` or `setup --remote-path`.
"""
function remote_layout_path(
        local_abs_dir::AbstractString,
        local_application_repo_root::AbstractString,
    )::String
    ld = canonical_local_path(local_abs_dir)
    root = canonical_local_path(local_application_repo_root)
    rroot = resolve_remote_project_root(root)
    if ld == root
        return rroot
    end
    rootpfx = endswith(root, '/') ? root : root * '/'
    if startswith(ld, rootpfx)
        rel = String(relpath(ld, root))
        return _join_under_remote_root(rroot, rel)
    end
    return ld
end

"""Test doubles replace ssh, rsync, and local juliaup only when this is `1`."""
function _test_doubles_on()::Bool
    return strip(get(ENV, "DISTSSHKIT_TEST", "")) == "1"
end

"""Julia argv for `DISTSSHKIT_TEST_SSH` / `.jl` rsync doubles (`--compile=min`)."""
function _test_double_julia_argv(script::AbstractString)::Vector{String}
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    return [julia, "--startup-file=no", "--compile=min", abspath(script)]
end

function _host_sync_remote_shell_cmd(host::String, remote_script::String)::Cmd
    custom = _test_doubles_on() ? strip(get(ENV, "DISTSSHKIT_TEST_SSH", "")) : ""
    if !isempty(custom)
        return Cmd(vcat(_test_double_julia_argv(custom), [host, remote_script]))
    end
    # `-n`: do not forward kit stdin (juliaup/git must not wait on a TTY pipe).
    return _ssh_cmd(["-n", ssh_opts()..., _ssh_host_args(host, remote_script)...])
end

# Hosts whose login shell already passed the POSIX probe. Failures are not stored.
const _REMOTE_POSIX_SHELL_OK = Set{String}()
const _REMOTE_POSIX_SHELL_LOCK = ReentrantLock()

"""Drop cached POSIX login-shell passes (`host=nothing` → all hosts)."""
function _clear_remote_posix_shell_cache!(host::Union{Nothing, AbstractString} = nothing)
    lock(_REMOTE_POSIX_SHELL_LOCK) do
        if host === nothing
            empty!(_REMOTE_POSIX_SHELL_OK)
        else
            delete!(_REMOTE_POSIX_SHELL_OK, String(strip(String(host))))
        end
    end
    return nothing
end

function _remote_posix_shell_cached(host::AbstractString)::Bool
    h = String(host)
    return lock(_REMOTE_POSIX_SHELL_LOCK) do
        return h in _REMOTE_POSIX_SHELL_OK
    end
end

function _remote_posix_shell_remember!(host::AbstractString)
    h = String(host)
    lock(_REMOTE_POSIX_SHELL_LOCK) do
        push!(_REMOTE_POSIX_SHELL_OK, h)
    end
    return nothing
end

"""`echo \$SHELL` as its own remote command. Fish aborts a `-c` string on a parse error."""
const _REMOTE_SHELL_NAME_SCRIPT = "echo \$SHELL"

function _posix_probe_nonce()::String
    return string(rand(UInt128); base = 16)
end

function _posix_probe_marker(nonce::AbstractString)::String
    return "__DSR_POSIX_OK_$(nonce)__"
end

"""POSIX `case` probe. The marker is random so rc-file stdout cannot fake a pass."""
function _posix_probe_script(nonce::AbstractString)::String
    return "case x in x) echo $(_posix_probe_marker(nonce));; esac"
end

function _remote_shell_capture(
        host::String,
        script::String,
    )::Union{Nothing, @NamedTuple{code::Int, out::String}}
    out_buf = IOBuffer()
    err_buf = IOBuffer()
    proc = try
        run(
            pipeline(
                ignorestatus(_host_sync_remote_shell_cmd(host, script));
                stdout = out_buf,
                stderr = err_buf,
            );
            wait = true,
        )
    catch
        return nothing
    end
    code = proc.exitcode
    code isa Integer || return nothing
    return (code = Int(code), out = String(take!(out_buf)))
end

"""A `DISTSSHKIT_TEST_SSH` double is not a login shell unless the test asks."""
function _posix_probe_is_strict()::Bool
    _test_doubles_on() || return true
    isempty(strip(get(ENV, "DISTSSHKIT_TEST_SSH", ""))) && return true
    # Test double only. Not a user setting, and it does not disable the probe.
    return strip(get(ENV, "DISTSSHKIT_TEST_POSIX_SHELL", "1")) == "0"
end

"""`:pass`, `:fail`, or `:unknown`. Exit 255 and a probe that did not run are unknown.

A test double that exits 0 without the marker is a pass (it is not a shell).
Any other double exit is unknown. `DISTSSHKIT_TEST_POSIX_SHELL=0` keeps the strict check.
"""
function _probe_remote_login_shell(host::String)::Symbol
    nonce = _posix_probe_nonce()
    got = _remote_shell_capture(host, _posix_probe_script(nonce))
    got === nothing && return :unknown
    got.code == 255 && return :unknown
    occursin(_posix_probe_marker(nonce), got.out) && return :pass
    _posix_probe_is_strict() || return got.code == 0 ? :pass : :unknown
    return :fail
end

function _shell_name_from_stdout(stdout::AbstractString)::Union{Nothing, String}
    last = ""
    saw = false
    for line in eachsplit(String(stdout), '\n')
        s = strip(line)
        isempty(s) && continue
        last = String(s)
        saw = true
    end
    saw || return nothing
    occursin(r"^[A-Za-z0-9_./+-]+$", last) || return nothing
    length(last) > 128 && return nothing
    return last
end

"""Last stdout line of `echo \$SHELL`, or `nothing` when that command is not usable."""
function _remote_login_shell_name(host::String)::Union{Nothing, String}
    got = _remote_shell_capture(host, _REMOTE_SHELL_NAME_SCRIPT)
    got === nothing && return nothing
    got.code == 255 && return nothing
    return _shell_name_from_stdout(got.out)
end

function _nonposix_login_shell_sentence(shell::Union{Nothing, String})::String
    named = shell === nothing ? "" : " ($(shell))"
    return "The remote login shell appears to be non-POSIX$(named). See `help setup`."
end

"""
Hint when `code` is a remote-command failure and the login shell is non-POSIX.

Exit 0 and SSH's own exit 255 do not probe. A passed probe is cached per host.
A failed or inconclusive probe is not cached. `nothing` leaves the original error as it is.
"""
function _remote_shell_failure_hint(host::AbstractString, code::Integer)::Union{Nothing, String}
    c = Int(code)
    (c == 0 || c == 255) && return nothing
    h = String(strip(String(host)))
    isempty(h) && return nothing
    _remote_posix_shell_cached(h) && return nothing
    verdict = _probe_remote_login_shell(h)
    if verdict === :pass
        _remote_posix_shell_remember!(h)
        return nothing
    elseif verdict === :fail
        return _nonposix_login_shell_sentence(_remote_login_shell_name(h))
    else
        return nothing
    end
end

function _remote_command_failure_text(
        host::AbstractString,
        code::Integer,
        stderr::AbstractString,
        hint::AbstractString,
    )::String
    lines = String["remote command on $(String(strip(String(host)))) failed (exit $(Int(code))):"]
    err = strip(String(stderr))
    if !isempty(err)
        for line in eachsplit(err, '\n')
            push!(lines, "  " * String(line))
        end
    end
    push!(lines, String(hint))
    return join(lines, '\n')
end

"""Throw when `code` is a definitive non-POSIX login shell. Otherwise return."""
function _throw_if_nonposix_shell(
        host::AbstractString,
        code::Integer,
        stderr::AbstractString,
    )::Nothing
    hint = _remote_shell_failure_hint(host, code)
    hint === nothing && return nothing
    throw(ArgumentError(_remote_command_failure_text(host, code, stderr, hint)))
end

function _throw_if_nonposix_shell(host::AbstractString, err)::Nothing
    code = _remote_failure_exit_code(err)
    code === nothing && return nothing
    return _throw_if_nonposix_shell(host, code, sprint(showerror, err))
end

function _append_remote_shell_hint(
        host::AbstractString,
        code::Integer,
        text::AbstractString,
    )::String
    body = String(text)
    hint = _remote_shell_failure_hint(host, code)
    hint === nothing && return body
    occursin(hint, body) && return body
    isempty(strip(body)) && return hint
    return rstrip(body) * "\n" * hint
end

function _remote_failure_exit_code(err)::Union{Nothing, Int}
    err isa Base.ProcessFailedException || return nothing
    for proc in err.procs
        code = proc.exitcode
        code isa Integer || continue
        return Int(code)
    end
    return nothing
end

function _cmd_exec(cmd)::Union{Nothing, Vector{String}}
    if cmd isa Cmd
        return cmd.exec
    elseif cmd isa Base.CmdRedirect
        return _cmd_exec(cmd.cmd)
    else
        return nothing
    end
end

function _test_ssh_double_path()::Union{Nothing, String}
    _test_doubles_on() || return nothing
    script = strip(get(ENV, "DISTSSHKIT_TEST_SSH", ""))
    isempty(script) && return nothing
    return abspath(script)
end

function _remote_shell_host_from_exec(exec::Vector{String})::Union{Nothing, String}
    isempty(exec) && return nothing
    base = basename(exec[1])
    if base == "ssh" || base == "ssh.exe"
        idx = findlast(==("--"), exec)
        idx === nothing && return nothing
        idx + 2 <= length(exec) || return nothing
        host = exec[idx + 1]
        isempty(host) && return nothing
        return String(host)
    end
    script = _test_ssh_double_path()
    script === nothing && return nothing
    idx = findlast(x -> x == script || abspath(x) == script, exec)
    idx === nothing && return nothing
    idx + 2 <= length(exec) || return nothing
    host = exec[idx + 1]
    isempty(host) && return nothing
    return String(host)
end

function _remote_shell_host_from_error(err)::Union{Nothing, String}
    err isa Base.ProcessFailedException || return nothing
    for proc in err.procs
        exec = _cmd_exec(proc.cmd)
        exec === nothing && continue
        host = _remote_shell_host_from_exec(exec)
        host === nothing || return host
    end
    return nothing
end

function _append_remote_shell_hint_from_error(err, text::AbstractString)::String
    code = _remote_failure_exit_code(err)
    code === nothing && return String(text)
    host = _remote_shell_host_from_error(err)
    host === nothing && return String(text)
    return _append_remote_shell_hint(host, code, text)
end


"""`git rev-parse --show-toplevel` for `proj_dir`, or `nothing` when it is not a work tree."""
function git_work_tree(proj_dir::AbstractString)::Union{Nothing, String}
    _host_tool_present("git") || return nothing
    resolved = canonical_local_path(proj_dir)
    try
        s = strip(
            read(
                pipeline(_git_cmd(["-C", resolved, "rev-parse", "--show-toplevel"]); stderr = devnull),
                String,
            )
        )
        return isempty(s) ? nothing : canonical_local_path(s)
    catch
        return nothing
    end
end
