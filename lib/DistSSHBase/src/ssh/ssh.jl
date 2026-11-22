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

const _SSH_FORBIDDEN_OPT_OVERRIDES = Dict{String, String}(
    "batchmode" => "BatchMode=yes",
    "requesttty" => "RequestTTY=no",
)

function _ssh_o_option_keys(argv::AbstractVector{<:AbstractString})::Set{String}
    keys = Set{String}()
    for i in eachindex(argv)
        argv[i] == "-o" || continue
        i + 1 > length(argv) && break
        keyval = String(argv[i + 1])
        eq = findfirst('=', keyval)
        eq === nothing && continue
        push!(keys, lowercase(keyval[1:(eq - 1)]))
    end
    return keys
end

function _validate_distributed_ssh_o!(extra::AbstractVector{String})
    for i in 1:2:length(extra)
        extra[i] == "-o" || continue
        i + 1 > length(extra) && break
        keyval = extra[i + 1]
        eq = findfirst('=', keyval)
        eq === nothing && continue
        key = lowercase(keyval[1:(eq - 1)])
        haskey(_SSH_FORBIDDEN_OPT_OVERRIDES, key) || continue
        want = _SSH_FORBIDDEN_OPT_OVERRIDES[key]
        keyval != want && throw(
            ArgumentError(
                "DISTSSH_SSH_OPTS cannot override $(repr(want)); " *
                    "DistSSH requires non-interactive SSH",
            ),
        )
    end
    return nothing
end

function _default_ssh_o_values(; request_tty::Bool)
    connect = _ssh_whole_seconds(:ssh_connect, _SSH_CONNECT_TIMEOUT_S)
    alive_count = 10
    silent = _ssh_whole_seconds(:peer_silent, 600)
    alive_interval = max(1, round(Int, silent / alive_count))
    out = String[
        "BatchMode=yes",
        "ExitOnForwardFailure=yes",
        "ConnectTimeout=$connect",
        "StrictHostKeyChecking=accept-new",
        "ServerAliveInterval=$alive_interval",
        "ServerAliveCountMax=$alive_count",
        "TCPKeepAlive=yes",
    ]
    request_tty || push!(out, "RequestTTY=no")
    return out
end

"""
Build SSH options. `DISTSSH_SSH_OPTS` tokens come first; kit defaults for
each `-o` name follow only when that name is absent (OpenSSH uses the first
value on the command line). Forbidden overrides in ENV still throw.
A leftover `DISTRIBUTED_SSH_OPTS` is an error.
"""
function build_ssh_opts(; request_tty::Bool = false)
    throw_if_legacy_env!(ENV)
    custom = strip(get(ENV, "DISTSSH_SSH_OPTS", ""))
    extra = isempty(custom) ? String[] : _split_ssh_opts(custom)
    !isempty(extra) && _validate_distributed_ssh_o!(extra)
    user_keys = _ssh_o_option_keys(extra)
    defaults = String[]
    for kv in _default_ssh_o_values(; request_tty = request_tty)
        key = lowercase(split(kv, '=', limit = 2)[1])
        key in user_keys && continue
        push!(defaults, "-o", kv)
    end
    return vcat(extra, defaults)
end

"""Argv prefix for every `ssh` invocation (BatchMode and askpass lock)."""
function ssh_noninteractive_env()::Dict{String, String}
    return Dict{String, String}(
        "SSH_ASKPASS_REQUIRE" => "never",
        "SSH_ASKPASS" => "",
    )
end

"""Split `DISTSSH_SSH_OPTS` with shell quoting. Unmatched quotes throw `ArgumentError`."""
function _split_ssh_opts(custom::AbstractString)::Vector{String}
    try
        return String[String(x) for x in Base.shell_split(custom)]
    catch e
        e isa ErrorException || rethrow()
        throw(ArgumentError("DISTSSH_SSH_OPTS: $(e.msg)"))
    end
end

"""
    ssh_opts(; request_tty=false) -> Vector{String}

SSH argv flags for `ssh` / `scp`.

Reads `DISTSSH_SSH_OPTS` **live** (not frozen at package precompile). Prefer
this over a `const` so E2E / ProxyJump overrides apply in the same process.

Non-empty `DISTSSH_SSH_OPTS` is split with `Base.shell_split` and placed
**before** kit defaults. For each `-o` option name, the first token on the
command line wins, so ENV can override timeouts and extras like `-F`. Kit
still fills any missing default names (`BatchMode=yes`, and so on). An
unmatched quote throws `ArgumentError`.
`request_tty` only changes which default names are filled: `false` includes
`RequestTTY=no` when ENV did not set it; `true` omits that default. Use
`-o RequestTTY=no`,
not `ssh -T`: these flags are also passed to `scp` (`scp -T` is unrelated).
Does not insert `-t` (that flag is `ssh`-only).
"""
function ssh_opts(; request_tty::Bool = false)::Vector{String}
    return String[String(x) for x in build_ssh_opts(; request_tty = request_tty)]
end

"""`ssh` / `scp` / `git` on `PATH`, or throw `ArgumentError`."""
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
function _ssh_cmd(args::AbstractVector)::Cmd
    cmd = _host_tool_cmd("ssh", args)
    return addenv(cmd, ssh_noninteractive_env())
end

# Seconds added on top of `ConnectTimeout` for pubkey/password auth after TCP connect.
const _SSH_AUTH_MARGIN_S = 20
const _SSH_PHASE_ALIVE_INTERVAL = 5
const _SSH_PHASE_ALIVE_COUNT = 1

"""
Wall-clock limit for the **first** short POSIX probe on a host (connect plus auth).

`DISTSSH_WAIT_SSH_AUTH` overrides the default (`ConnectTimeout` + margin).
"""
function ssh_auth_timeout_seconds()::Float64
    connect = Float64(_ssh_whole_seconds(:ssh_connect, _SSH_CONNECT_TIMEOUT_S))
    auth = wait_seconds(:ssh_auth, connect + _SSH_AUTH_MARGIN_S)
    return max(auth, connect + 1.0)
end

"""OpenSSH flags for parallel short remote phases (`kill`, tagged `pkill`).

Forced `-o` tokens are placed before forwarded user opts so they win over
`DISTSSH_SSH_OPTS` (OpenSSH uses the first value per option name).
"""
function ssh_phase_argv(;
        request_tty::Bool = false,
        explicit_port::Union{Nothing, Int} = nothing,
    )::Vector{String}
    connect = _ssh_whole_seconds(:ssh_connect, _SSH_CONNECT_TIMEOUT_S)
    forced = String[
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=$connect",
        "-o", "ServerAliveInterval=$(_SSH_PHASE_ALIVE_INTERVAL)",
        "-o", "ServerAliveCountMax=$(_SSH_PHASE_ALIVE_COUNT)",
    ]
    return vcat(
        forced,
        ssh_forwarded_opts(; explicit_port = explicit_port, request_tty = request_tty),
    )
end

function _scp_cmd(args::AbstractVector)::Cmd
    cmd = _host_tool_cmd("scp", args)
    return addenv(cmd, ssh_noninteractive_env())
end

function _ssh_kill_local!(proc::Base.Process)
    try
        process_running(proc) && kill(proc, Base.SIGKILL)
    catch
    end
    timedwait(() -> process_exited(proc), 2.0; pollint = 0.05)
    process_running(proc) && try
        kill(proc, Base.SIGKILL)
    catch
    end
    return nothing
end

function _ssh_auth_timeout_error(seconds::Real)
    return ArgumentError(
        "SSH timed out after $(round(Float64(seconds); digits = 1))s. " *
            "Check: ssh -o BatchMode=yes -o ConnectTimeout=5 HOST echo ok",
    )
end

"""Wait on a kit-started `ssh` child until it exits (no Julia-side kill)."""
function ssh_wait_process!(proc::Base.Process)::Base.Process
    Base.wait(proc)
    return proc
end

function _ssh_cmd_for_ignorestatus(cmd)::Cmd
    while cmd isa Base.CmdRedirect
        cmd = cmd.cmd
    end
    cmd isa Cmd || error("internal: run_ssh expects Cmd or CmdRedirect")
    return cmd
end

function _ssh_run_throws_on_failure(cmd)::Bool
    return !_ssh_cmd_for_ignorestatus(cmd).ignorestatus
end

"""
Run one kit-owned `ssh` / `scp` command and wait until the child exits.

Uses the same stdio and `ignorestatus` rules as `Base.run`: a non-zero exit
throws `ProcessFailedException` unless the root `Cmd` was built with
`ignorestatus`. The Julia-side auth budget applies only to the first short
POSIX login-shell probe per host (cached for the process), not to every session.
"""
function run_ssh(cmd; wait::Bool = true)::Base.Process
    proc = wait ? run(cmd, stdin, stdout, stderr; wait = false) : run(cmd; wait = false)
    wait || return proc
    Base.wait(proc)
    if _ssh_run_throws_on_failure(cmd) && !Base.success(proc)
        throw(Base.ProcessFailedException(Base.Process[proc]))
    end
    return proc
end

"""First SSH probe on a host: bounded by [`ssh_auth_timeout_seconds`](@ref)."""
function _run_ssh_auth_bounded(cmd)::Base.Process
    proc = run(cmd; wait = false)
    seconds = ssh_auth_timeout_seconds()
    if timedwait(() -> process_exited(proc), Float64(seconds); pollint = 0.05) !== :ok
        _ssh_kill_local!(proc)
        throw(_ssh_auth_timeout_error(seconds))
    end
    Base.wait(proc)
    return proc
end

"""Run `_ssh_cmd(argv)` and return captured stdout (stderr to `devnull` by default)."""
function _read_ssh(argv::AbstractVector)::String
    typed = String[String(a) for a in argv]
    return _read_ssh(typed)
end

function _read_ssh(argv::AbstractVector{<:AbstractString})::String
    out_buf = IOBuffer()
    run_ssh(
        pipeline(_ssh_cmd(argv); stdout = out_buf, stderr = devnull);
        wait = true,
    )
    return String(take!(out_buf))
end

"""`--` then `host`, then `args`. A name that starts with `-` is rejected."""
function _ssh_host_args(host::AbstractString, args::AbstractString...)::Vector{String}
    dest = validate_ssh_host(host)
    return String["--", dest, String.(args)...]
end

function _ssh_o_keyvalue_is_port(keyval::AbstractString)::Bool
    eq = findfirst('=', keyval)
    eq === nothing && return false
    key = strip(String(keyval[1:(eq - 1)]))
    return lowercase(key) == "port"
end

function _ssh_o_token_is_port(keyval::AbstractString)::Bool
    _ssh_o_keyvalue_is_port(keyval) && return true
    parts = split(String(keyval); limit = 2)
    return length(parts) == 2 && lowercase(strip(parts[1])) == "port" && !isempty(strip(parts[2]))
end

function _ssh_argv_port_value(token::AbstractString)::Union{Nothing, Int}
    return tryparse(Int, String(strip(token)))
end

function _attached_ssh_port_flag(flag::AbstractString)::Bool
    return occursin(r"^-p\d+$", String(flag))
end

function _attached_scp_port_flag(flag::AbstractString)::Bool
    return occursin(r"^-P\d+$", String(flag))
end

"""Drop ssh port spellings (`-p`, `-o Port…`) but keep ssh `-P` config tags."""
function _ssh_ssh_argv_without_port_flags(argv::AbstractVector{<:AbstractString})::Vector{String}
    out = String[]
    i = 1
    n = length(argv)
    while i <= n
        a = String(argv[i])
        if a == "-p"
            i += 2
            continue
        elseif _attached_ssh_port_flag(a)
            i += 1
            continue
        elseif a == "-o" && i + 1 <= n
            nxt = String(argv[i + 1])
            if _ssh_o_token_is_port(nxt)
                i += 2
                continue
            elseif lowercase(strip(nxt)) == "port" && i + 2 <= n
                i += 3
                continue
            end
        elseif startswith(a, "-o") && length(a) > 2 && _ssh_o_token_is_port(SubString(a, 3))
            i += 1
            continue
        end
        push!(out, a)
        i += 1
    end
    return out
end

"""Drop scp port spellings (`-P`, `-o Port…`) but keep scp `-p` (preserve times)."""
function _scp_argv_without_port_flags(argv::AbstractVector{<:AbstractString})::Vector{String}
    out = String[]
    i = 1
    n = length(argv)
    while i <= n
        a = String(argv[i])
        if a == "-P"
            i += 2
            continue
        elseif a == "-p" && i + 1 <= n
            if _ssh_argv_port_value(argv[i + 1]) !== nothing
                i += 2
                continue
            end
        elseif _attached_scp_port_flag(a)
            i += 1
            continue
        elseif _attached_ssh_port_flag(a)
            i += 1
            continue
        elseif a == "-o" && i + 1 <= n
            nxt = String(argv[i + 1])
            if _ssh_o_token_is_port(nxt)
                i += 2
                continue
            elseif lowercase(strip(nxt)) == "port" && i + 2 <= n
                i += 3
                continue
            end
        elseif startswith(a, "-o") && length(a) > 2 && _ssh_o_token_is_port(SubString(a, 3))
            i += 1
            continue
        end
        push!(out, a)
        i += 1
    end
    return out
end

"""OpenSSH `ssh` destination string (same as the placement host body; port is passed via `-p`)."""
function ssh_openssh_dest(dest::AbstractString)::String
    d = String(strip(dest))
    validate_ssh_host(d; shown = dest)
    return d
end

"""
`ssh_opts()` with conflicting port flags removed when `explicit_port` is set.
"""
function ssh_forwarded_opts(;
        explicit_port::Union{Nothing, Int} = nothing,
        request_tty::Bool = false,
    )::Vector{String}
    base = String.(ssh_opts(; request_tty = request_tty))
    explicit_port === nothing && return base
    return _ssh_ssh_argv_without_port_flags(base)
end

"""
`ssh_opts()` with scp port flags removed when `explicit_port` is set.
"""
function scp_forwarded_opts(;
        explicit_port::Union{Nothing, Int} = nothing,
        request_tty::Bool = false,
    )::Vector{String}
    base = String.(ssh_opts(; request_tty = request_tty))
    explicit_port === nothing && return base
    return _scp_argv_without_port_flags(base)
end

"""OpenSSH `-p` when the placement token carried an explicit port."""
function _ssh_explicit_port_args(port::Union{Nothing, Int})::Vector{String}
    port === nothing && return String[]
    return String["-p", string(port)]
end

"""`ssh` / `Distributed.addprocs` flags: forwarded opts plus explicit `-p` when set."""
function ssh_connection_ssh_opts(host::AbstractString)::Vector{String}
    _, port = parse_ssh_endpoint(host)
    return vcat(ssh_forwarded_opts(explicit_port = port), _ssh_explicit_port_args(port))
end

"""Forwarded `ssh_opts` plus `-p` and `-- dest …` for one connection."""
function _ssh_remote_session_argv(host::AbstractString, args::AbstractString...)::Vector{String}
    _, port = parse_ssh_endpoint(host)
    return vcat(
        ssh_forwarded_opts(explicit_port = port),
        _ssh_host_connection_args(host, args...),
    )
end

"""`--` then an already-validated OpenSSH destination."""
function _ssh_host_openssh_args(dest::AbstractString, args::AbstractString...)::Vector{String}
    h = String(strip(dest))
    return String["--", h, String.(args)...]
end

"""Split a canonical SSH endpoint into OpenSSH argv tail (`-p` then `-- dest …`)."""
function _ssh_host_connection_args(host::AbstractString, args::AbstractString...)::Vector{String}
    dest, port = parse_ssh_endpoint(host)
    validate_ssh_host(dest; shown = host)
    open_dest = ssh_openssh_dest(dest)
    return vcat(_ssh_explicit_port_args(port), _ssh_host_openssh_args(open_dest, args...))
end

"""Explicit `-p` from a worker `sshflags` `Cmd` (Distributed `addprocs`)."""
function explicit_port_from_sshflags(flags::Cmd)::Union{Nothing, Int}
    exec = flags.exec
    for i in 1:(length(exec) - 1)
        String(exec[i]) == "-p" || continue
        parsed = tryparse(Int, String(exec[i + 1]))
        return parsed
    end
    return nothing
end

"""OpenSSH `scp -P` when the placement token carried an explicit port."""
function _scp_explicit_port_args(port::Union{Nothing, Int})::Vector{String}
    port === nothing && return String[]
    return String["-P", string(port)]
end

"""
`scp` port prefix and `user@host:remote_path` spec for a canonical SSH endpoint.
"""
function _scp_remote_file_spec(
        host::AbstractString,
        remote_path::AbstractString,
    )::Tuple{Vector{String}, String}
    _, port = parse_ssh_endpoint(host)
    machine = ssh_scp_machine(host)
    remote = String(remote_path)
    any(iscntrl, remote) &&
        throw(ArgumentError("scp remote path contains a control character"))
    spec = string(machine, ":", remote)
    return (_scp_explicit_port_args(port), spec)
end

"""`scp` argv prefix: forwarded opts plus explicit `-P` when the endpoint names a port."""
function scp_connection_argv(host::AbstractString)::Vector{String}
    _, port = parse_ssh_endpoint(host)
    return vcat(scp_forwarded_opts(explicit_port = port), _scp_explicit_port_args(port))
end

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
        dest, port = parse_ssh_endpoint(h)
        open_dest = ssh_openssh_dest(dest)
        # -n: no stdin; -G dumps effective config (User, HostName, …).
        out = _read_ssh(
            vcat(
                String["-n"],
                ssh_forwarded_opts(explicit_port = port)...,
                _ssh_explicit_port_args(port)...,
                String["-G"],
                _ssh_host_openssh_args(open_dest)...,
            ),
        )
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
function ssh_scp_machine(host::AbstractString)::String
    endpoint = String(strip(host))
    isempty(endpoint) && return endpoint
    dest, _ = parse_ssh_endpoint(endpoint)
    h = validate_ssh_host(dest)
    occursin('@', h) && return h
    u = ssh_config_user(endpoint)
    return u === nothing ? h : string(u, '@', h)
end

function ssh_addprocs_machine(host::AbstractString)::String
    endpoint = String(strip(host))
    isempty(endpoint) && return endpoint
    dest, _ = parse_ssh_endpoint(endpoint)
    validate_ssh_host(dest; shown = endpoint)
    h = ssh_openssh_dest(dest)
    occursin('@', h) && return h
    u = ssh_config_user(endpoint)
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
    return _read_ssh(_ssh_remote_session_argv(host, remote))
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
A path goes through `_remote_shell_path_word`, which rejects a control
character. A host goes through `validate_ssh_host`, which rejects a
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
    _ensure_posix_login_shell!(h)
    inner = _run_on_host_remote_sh(argv; julia = julia, detect = detect)
    _, port = parse_ssh_endpoint(h)
    args = ssh_forwarded_opts(explicit_port = port, request_tty = tty)
    tty && push!(args, "-t")
    append!(args, _ssh_host_connection_args(h, inner))
    cmd = ignorestatus(_ssh_cmd(args))
    return wait ? run_ssh(cmd) : run(cmd; wait = false)
end

# Process-local cache of found Julia paths only. A miss is not stored.
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

"""Run `script` on `host`. Returns `(status, stdout)`.

`status` is [`shell_status`](@ref): a signal is `128 + termsignal`, and any
other exit is `exitcode`.

SSH's own failure (exit 255) throws `ArgumentError` from [`summarize_ssh_error`](@ref).
A non-POSIX login shell throws `ArgumentError` and points to `help setup`
before `script` runs. Other non-zero exits are returned so a missing command
can stay `nothing`. A later failure still diagnoses the login shell when the
up-front probe was unknown.
"""
function _remote_shell_status_parts(
        host::String,
        script::AbstractString,
    )::Tuple{Int, String, String}
    _ensure_posix_login_shell!(host)
    err_buf = IOBuffer()
    out_buf = IOBuffer()
    cmd = _host_sync_remote_shell_cmd(host, script)
    proc = try
        run_ssh(pipeline(ignorestatus(cmd); stdout = out_buf, stderr = err_buf); wait = true)
    catch e
        _rethrow_missing_host_tool(e)
        rethrow()
    end
    code = shell_status(proc)
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
    return code, out, err
end

function _remote_shell_status(host::String, script::AbstractString)::Tuple{Int, String}
    code, out, _ = _remote_shell_status_parts(host, script)
    return code, out
end

"""Stdout, stderr, and exit code for a failed remote shell invocation."""
function shell_status_failure_message(
        out::AbstractString,
        err::AbstractString,
        code::Int,
    )::String
    parts = String[]
    o = strip(String(out))
    e = strip(String(err))
    !isempty(o) && push!(parts, o)
    !isempty(e) && push!(parts, e)
    isempty(parts) && return "exit $code"
    return join(parts, " ") * " (exit $code)"
end

"""Detect Julia path on remote host via SSH (executable + parseable `--version`).

Returns `nothing` when the remote shell ran and no Julia was found. That miss
is not cached, so a later call in the same process can pick up Julia after the
environment or install changes. A found path is cached. SSH transport failure
(exit 255) throws `ArgumentError` and is not cached. A failed command whose
login shell is non-POSIX also throws `ArgumentError` (see `help setup`) and is
not cached.
"""
function detect_julia_path(host::String)::Union{Nothing, String}
    h = String(strip(host))
    isempty(h) && return nothing
    if haskey(_DETECT_JULIA_PATH_CACHE, h)
        return _DETECT_JULIA_PATH_CACHE[h]
    end
    found = _detect_julia_path_uncached(h)
    if found !== nothing
        _DETECT_JULIA_PATH_CACHE[h] = found
    end
    return found
end

"""`--version` over the setup SSH transport (honors an injected test transport)."""
function _remote_julia_reports_version(host::String, path::AbstractString)::Bool
    pq = _remote_shell_path_word(String(path))
    try
        out = let buf = IOBuffer()
            run_ssh(
                pipeline(_host_sync_remote_shell_cmd(host, "$pq --version"); stdout = buf, stderr = devnull);
                wait = true,
            )
            String(take!(buf))
        end
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
                result = let buf = IOBuffer()
                    run_ssh(
                        pipeline(
                            _host_sync_remote_shell_cmd(host, "test -x $path && echo $path");
                            stdout = buf,
                            stderr = devnull,
                        );
                        wait = true,
                    )
                    String(take!(buf))
                end
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
Absolute project root for `addprocs` on `host`.

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
        s = strip(_read_ssh(_ssh_remote_session_argv(host, inner)))
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
        s = strip(_read_ssh(_ssh_remote_session_argv(host, inner)))
        return isempty(s) ? nothing : s
    catch e
        _throw_if_nonposix_shell(host, e)
        return nothing
    end
end

# Remote resource detection (same probe as collect_host_facts; missing is nothing).

"""Get total memory (GB) for a remote host via SSH."""
function get_remote_total_gb(host::String)
    facts = collect_host_facts(host)
    facts.reachable || return nothing
    facts.total_memory_bytes === nothing && return nothing
    return Float64(facts.total_memory_bytes) / 1024^3
end

"""Get CPU core count for a remote host via SSH."""
function get_remote_nproc(host::String)
    facts = collect_host_facts(host)
    facts.reachable || return nothing
    return facts.ncpu
end

"""
Absolute path for `remote_path` on `host` — the kit-parent/remote path boundary.

Use this before any kit-parent-side join, compare, or `relpath` that
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

# Remote location roles (do not collapse these into one path):
# - deployment/container root: [`remote_deploy_root`](@ref) — receives ship `ships/`
# - git clone destination: [`remote_git_clone_dest`](@ref)
# - worker `--project`: [`resolve_remote_project_root`](@ref) (deploy + member rel)
# - snapshot source: local pack root (unchanged by these helpers)
# - output / recovery collect: mapped via [`remote_layout_path`](@ref) under the
#   active remote project root
#
# Precedence for a deployment root:
# 1. Explicit per-call `cli_override` (`--deploy-root` / `session.remote`)
# 2. Caller `DISTSSH_REMOTE_PROJECT_ROOT`
# 3. [`default_remote_project_path`](@ref) from local `env_dir`
# A per-call override must not be written back as a process-global default.

"""
Default remote layout used by `setup.jl` when paths are not overridden:
`~/basename(parent)/basename(local_project_root)` (tilde for remote-shell expansion).

`local_project_root` is normally [`resolve_pkg_env`](@ref) `env_dir` (Manifest
directory when present). Tilde is expanded on the remote host only.
"""
function default_remote_project_path(local_project_root::AbstractString)::String
    root = canonical_local_path(local_project_root)
    return joinpath("~", basename(dirname(root)), basename(root))
end

"""Remote tree root for `local_tree` (override, else `DISTSSH_REMOTE_PROJECT_ROOT`, else the default layout)."""
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
    env = strip(get(ENV, "DISTSSH_REMOTE_PROJECT_ROOT", ""))
    if !isempty(env)
        _reject_control_path(env)
        return env
    end
    root = default_remote_project_path(local_tree)
    _reject_control_path(root)
    return root
end

"""
Directory on the worker that receives `setup ship-tree` of [`resolve_pkg_env`](@ref) `env_dir`.

An override (`--deploy-root` / `DISTSSH_REMOTE_PROJECT_ROOT`) is this tree
root, not the member directory. Workspace member relative paths are applied
only by [`resolve_remote_project_root`](@ref), not here.
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

Same override rules as `remote_deploy_root`. When the Manifest lives in
a parent of the member, this is `deploy_root` plus that relative path once
([`julia_project_rel`](@ref)). A single-project tree returns the deploy root
unchanged. Does not `abspath` tilde paths.
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
when it is `~`, `/`, or a single directory under `/`. Pass `--deploy-root` so
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
                "pass --deploy-root so the git root is not ~, /, or a single directory under /",
        ),
    )
    return _checked_remote_dest(walked)
end

"""
Path `setup delete` removes.

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
                "Pass --deploy-root for the remote path of the git root.",
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

"""Layout path for `DISTSSH_REMOTE_PROJECT_ROOT` (kit parent ENV / `execute!`).

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

"""
Read `origin` from `proj_dir` and return a clone URL (HTTPS GitHub → SSH).

`nothing` when the path is not a git work tree or `origin` is absent.
Throws when git fails on a tree that has `.git` metadata.
"""
function clone_url_from_local_origin(proj_dir::AbstractString)::Union{Nothing, String}
    resolved = canonical_local_path(proj_dir)
    if !_host_tool_present("git")
        _ancestor_dot_git_entry(resolved) &&
            throw(ArgumentError(explain_host_tool_missing("git")))
        return nothing
    end
    origin_url, code, detail = _git_read_local(resolved, ["remote", "get-url", "origin"])
    if code == 0
        isempty(origin_url) && return nothing
        return normalize_git_clone_url(origin_url)
    end
    _git_absent_plain_directory(code, detail, resolved) && return nothing
    code == 2 && occursin("no such remote", lowercase(detail)) && return nothing
    throw(ArgumentError(explain_git_work_tree_failed(resolved, code, detail)))
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
`setup git-clone` (`~/Parent/RepoName`). Override with
`DISTSSH_REMOTE_PROJECT_ROOT` or `--deploy-root`.
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

"""Julia argv for a test SSH `.jl` double (`--compile=min`)."""
function _test_double_julia_argv(script::AbstractString)::Vector{String}
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    return [julia, "--startup-file=no", "--compile=min", abspath(script)]
end

"""ENV for an injected test SSH Julia child (see `test/support/subprocess.jl`)."""
function _fake_double_child_julia_env()::Dict{String, String}
    skip = Set(("JULIA_PROJECT", "JULIA_LOAD_PATH"))
    env = Dict{String, String}()
    for (k, v) in ENV
        ks = String(k)
        ks in skip && continue
        vs = String(v)
        isempty(vs) && continue
        env[ks] = vs
    end
    env["JULIA_LOAD_PATH"] = _child_load_path_string()
    return env
end

function _child_load_path_string()::String
    sep = Sys.iswindows() ? ';' : ':'
    return "@" * sep * "@stdlib"
end

function _host_sync_remote_shell_cmd(
        host::String,
        remote_script::String;
        forward_stdin::Bool = false,
    )::Cmd
    t = _injected_ssh[]
    if t !== nothing
        cmd = t.remote_cmd(host, remote_script; forward_stdin = forward_stdin)
        cmd !== nothing && return cmd
    end
    # Default `-n`: do not forward kit stdin (juliaup/git must not wait on a TTY).
    # Tar ship needs stdin (`forward_stdin=true`).
    flags = forward_stdin ? String[] : String["-n"]
    return _ssh_cmd(vcat(flags, _ssh_remote_session_argv(host, remote_script)))
end

# Login-shell POSIX passes. Key is host plus live `ssh_opts()` (not host alone:
# `DISTSSH_SSH_OPTS` can change the login user). Failures are not stored.
const _REMOTE_POSIX_SHELL_OK = Set{String}()
const _REMOTE_POSIX_SHELL_LOCK = ReentrantLock()

function _posix_shell_cache_key(host::AbstractString)::String
    return string(strip(String(host)), '\0', join(ssh_opts(), '\0'))
end

"""Drop cached POSIX login-shell passes (`host=nothing` → all hosts)."""
function _clear_remote_posix_shell_cache!(host::Union{Nothing, AbstractString} = nothing)
    lock(_REMOTE_POSIX_SHELL_LOCK) do
        if host === nothing
            empty!(_REMOTE_POSIX_SHELL_OK)
        else
            prefix = string(strip(String(host)), '\0')
            for k in collect(_REMOTE_POSIX_SHELL_OK)
                startswith(k, prefix) && delete!(_REMOTE_POSIX_SHELL_OK, k)
            end
        end
    end
    return nothing
end

function _remote_posix_shell_cached(host::AbstractString)::Bool
    key = _posix_shell_cache_key(host)
    return lock(_REMOTE_POSIX_SHELL_LOCK) do
        return key in _REMOTE_POSIX_SHELL_OK
    end
end

function _remote_posix_shell_remember!(host::AbstractString)
    key = _posix_shell_cache_key(host)
    lock(_REMOTE_POSIX_SHELL_LOCK) do
        push!(_REMOTE_POSIX_SHELL_OK, key)
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
        _run_ssh_auth_bounded(
            pipeline(
                ignorestatus(_host_sync_remote_shell_cmd(host, script));
                stdout = out_buf,
                stderr = err_buf,
            ),
        )::Base.Process
    catch e
        if e isa ArgumentError
            msg = sprint(showerror, e)
            occursin("SSH timed out after", msg) && rethrow()
        end
        return nothing
    end
    process_exited(proc) || return nothing
    return (code = shell_status(proc), out = String(take!(out_buf)))
end

"""A test SSH double is not a login shell unless the test asks."""
function _posix_probe_is_strict()::Bool
    _test_doubles_on() || return true
    t = _injected_ssh[]
    t === nothing && return true
    script = t.double_script()
    (script === nothing || isempty(script)) && return true
    return t.posix_strict()::Bool
end

"""`:pass`, `:fail`, or `:unknown`. Exit 255 and a probe that did not run are unknown.

A test double that exits 0 without the marker is a pass (it is not a shell).
Any other double exit is unknown. The injected transport can keep the strict check.
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

"""One-time POSIX login-shell probe. Rejects fish before `script` runs.

A pass is cached for this process and these `ssh_opts()`. Fail is not cached. Unknown leaves the
caller to run `script`; a later non-zero exit still calls
[`_throw_if_nonposix_shell`](@ref).
"""
function _ensure_posix_login_shell!(host::AbstractString)::Nothing
    h = String(strip(String(host)))
    isempty(h) && return nothing
    _remote_posix_shell_cached(h) && return nothing
    verdict = _probe_remote_login_shell(h)
    if verdict === :pass
        _remote_posix_shell_remember!(h)
        return nothing
    elseif verdict === :fail
        throw(ArgumentError(_nonposix_login_shell_sentence(_remote_login_shell_name(h))))
    end
    return nothing
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
        process_exited(proc) || continue
        return shell_status(proc)
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
    t = _injected_ssh[]
    t === nothing && return nothing
    _test_doubles_on() || return nothing
    script = t.double_script()
    script === nothing && return nothing
    s = strip(String(script))
    isempty(s) && return nothing
    return abspath(s)
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


"""True when `dir` or an ancestor has a `.git` file, directory, or symlink."""
function _ancestor_dot_git_entry(dir::AbstractString)::Bool
    cur = canonical_local_path(dir)
    prev = ""
    while cur != prev
        meta = joinpath(cur, ".git")
        (isfile(meta) || isdir(meta) || islink(meta)) && return true
        prev = cur
        cur = dirname(cur)
    end
    return false
end

function _git_work_tree_exit_code(e)::Int
    e isa ProcessFailedException || return 1
    for proc in Iterators.reverse(e.procs)
        process_exited(proc) || continue
        return shell_status(proc)
    end
    return 1
end

function _git_absent_plain_directory(code::Integer, detail::AbstractString, resolved::AbstractString)::Bool
    return code == 128 &&
        occursin("not a git repository", lowercase(String(detail))) &&
        !_ancestor_dot_git_entry(resolved)
end

function _git_missing_head(detail::AbstractString)::Bool
    ld = lowercase(String(detail))
    return occursin("unknown revision", ld) || occursin("ambiguous argument 'head'", ld)
end

"""Run `git -C resolved` with `args`. On success returns `(stdout, 0, stderr)`. On failure `(nothing, code, stderr)`."""
function _git_read_local(
        resolved::AbstractString,
        args::AbstractVector{<:AbstractString},
    )::Tuple{Union{Nothing, String}, Int, String}
    err_buf = IOBuffer()
    git_argv = vcat(["-C", String(resolved)], String[String(a) for a in args])
    cmd = addenv(_git_cmd(git_argv), "LC_ALL" => "C")
    try
        out = strip(read(pipeline(cmd; stderr = err_buf), String))
        return out, 0, strip(String(take!(err_buf)))
    catch e
        _rethrow_missing_host_tool(e)
        detail = strip(String(take!(err_buf)))
        return nothing, _git_work_tree_exit_code(e), detail
    end
end

"""
`git rev-parse --show-toplevel` for `proj_dir`, or `nothing` when it is not a work tree.

Throws when git fails on a tree that has `.git` metadata (or when git prints a real error).
"""
function git_work_tree(proj_dir::AbstractString)::Union{Nothing, String}
    resolved = canonical_local_path(proj_dir)
    if !_host_tool_present("git")
        _ancestor_dot_git_entry(resolved) &&
            throw(ArgumentError(explain_host_tool_missing("git")))
        return nothing
    end
    out, code, detail = _git_read_local(resolved, ["rev-parse", "--show-toplevel"])
    if code == 0
        isempty(out) && throw(ArgumentError(explain_git_work_tree_failed(resolved, 0, detail)))
        return canonical_local_path(out)
    end
    _git_absent_plain_directory(code, detail, resolved) && return nothing
    throw(ArgumentError(explain_git_work_tree_failed(resolved, code, detail)))
end
