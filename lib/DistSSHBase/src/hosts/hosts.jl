# Host tokens & SSH failure summaries (drive / go / setup)

"""Reserved token for this job's parent (not an SSH host)."""
const PARENT_HOST_NAME = "parent"

"""Prefix for an SSH child (`NAME` / `NAME:N`)."""
const CHILD_TOKEN_PREFIX = "child:"

"""Whether `host` denotes this job's parent in drive/go/hostinfo.

Only `parent` matches. `parenthost` is rejected by `parse_placement_token`.
A token `local` / `localhost` / `l` is an ordinary SSH child (`local`).

# Examples
```jldoctest
julia> using DistSSHRun

julia> DistSSHRun.is_parent_host_name("parent")
true

julia> DistSSHRun.is_parent_host_name("parenthost")
false

julia> DistSSHRun.is_parent_host_name("local")
false

julia> DistSSHRun.is_parent_host_name("worker1")
false
```
"""
function is_parent_host_name(host_name::AbstractString)::Bool
    return String(host_name) == PARENT_HOST_NAME
end

"""Reject the removed `parent` / `parent:N` token (head row is always implicit)."""
function throw_removed_parent_placement_token!(context::AbstractString, raw::AbstractString)
    s = String(strip(raw))
    base = contains(s, ':') ? strip(split(s, ':'; limit = 2)[1]) : s
    is_parent_host_name(base) || return nothing
    throw(
        ArgumentError(
            join_explained_message(
                "$(context): $(repr(raw)) was removed",
                "The head machine is always listed first; name SSH hosts only.",
            ),
        ),
    )
end

"""`ArgumentError` for removed `--local` / `-l`."""
function throw_removed_local_flag(arg::AbstractString)
    a = String(arg)
    throw(
        ArgumentError(
            "$(a) was removed; use --head-workers N",
        )
    )
end

function _placement_count_suffix(spec::AbstractString)::Tuple{String, Union{Nothing, Int}}
    s = strip(String(spec))
    if contains(s, ':')
        parts = split(s, ':'; limit = 2)
        n = try
            parse(Int, parts[2])
        catch
            throw(ArgumentError("invalid count in $(repr(spec)); use NAME:N with integer N"))
        end
        return String(parts[1]), n
    end
    return s, nothing
end

"""Format a machine placement token (`N*host` or bare host)."""
function format_placement_token(
        role::Symbol,
        name::String,
        n::Union{Nothing, Integer} = nothing,
    )::String
    role === :parent &&
        throw(ArgumentError("format_placement_token: head workers use --head-workers, not tokens"))
    nn = something(n === nothing ? 1 : Int(n), 1)
    return format_machine_token(nn, name)
end

format_placement_token(
    role::Symbol,
    name::AbstractString,
    n::Union{Nothing, Integer} = nothing,
) = format_placement_token(role, name isa String ? name : string(name), n)

const _PLACEMENT_HINT =
    "use `N*[user@]host[:port]` (quote `--hosts` so the shell does not glob `*`); bare host = 1 worker"

const IPV6_SSH_PLACEMENT_HINT =
    "use an SSH config Host alias instead of an IPv6 literal (in ~/.ssh/config: Host lab6, HostName ::1); then use lab6 or lab6:2222 in --hosts"

"""Host part of a placement endpoint (`user@host` or `host`, without `:port`)."""
function _ssh_hostpart_for_placement(dest::AbstractString)::String
    d = String(strip(dest))
    at = findlast('@', d)
    hostpart = at === nothing ? d : d[(at + 1):end]
    startswith(hostpart, "[") && return hostpart
    _hostpart_looks_like_ipv6_literal(hostpart) && return hostpart
    colon = findlast(':', hostpart)
    colon === nothing && return hostpart
    findnext(':', hostpart, colon + 1) !== nothing && return hostpart
    port_str = hostpart[(colon + 1):end]
    tryparse(Int, port_str) === nothing && return hostpart
    return hostpart[1:(colon - 1)]
end

function _hostpart_looks_like_ipv6_literal(hostpart::AbstractString)::Bool
    h = String(strip(hostpart))
    isempty(h) && return false
    startswith(h, "[") && return true
    occursin('%', h) && return true
    colon = findfirst(':', h)
    colon === nothing && return false
    return findnext(':', h, colon + 1) !== nothing
end

"""Reject bracketed or bare IPv6 literals in placement tokens and SSH endpoints."""
function reject_ipv6_ssh_host!(
        shown::AbstractString,
        hostpart::AbstractString,
    )::Nothing
    _hostpart_looks_like_ipv6_literal(hostpart) || return nothing
    throw(
        ArgumentError(
            join_explained_message(
                "$(repr(String(shown))): IPv6 literals are not supported in host tokens or SSH endpoints",
                "Hint: $IPV6_SSH_PLACEMENT_HINT",
            ),
        ),
    )
end

"""Hostname inside `user@host` or `host:path`."""
function _ssh_host_label(dest::AbstractString)::String
    d = String(dest)
    at = findlast('@', d)
    rest = at === nothing ? d : d[(at + 1):end]
    colon = findfirst(':', rest)
    return colon === nothing ? rest : rest[1:(colon - 1)]
end

"""
Reject an SSH destination that is an option or that contains a control character.

`user@-host` is rejected. `host:path` checks the host, and a control character
anywhere in `host` (including the path after `:`) is rejected. Returns `host`
stripped. `parent` is not an SSH destination.
"""
function validate_ssh_host(host::AbstractString; shown::Union{Nothing, AbstractString} = nothing)::String
    h = String(strip(host))
    label = _ssh_host_label(h)
    text = repr(shown === nothing ? h : String(shown))
    reject_ipv6_ssh_host!(text, _ssh_hostpart_for_placement(h))
    if isempty(h) || isempty(label)
        throw(ArgumentError("$text: empty host name. See help setup."))
    end
    if startswith(h, "-") || startswith(label, "-")
        throw(ArgumentError("$text: SSH name must not start with '-'. See help setup."))
    end
    if any(iscntrl, h)
        throw(ArgumentError("$text: SSH name contains a newline or NUL. See help setup."))
    end
    return h
end

function throw_legacy_placement_token(raw::AbstractString)
    s = String(raw)
    base = split(s, ':'; limit = 2)[1]
    if base == "parenthost" || base == "masterhost" || base == "childhost"
        throw(
            ArgumentError(
                "$(repr(s)) was removed; $_PLACEMENT_HINT",
            )
        )
    end
    return nothing
end

"""
Classify a go/drive/hostinfo placement token.

Returns `(role, name, n)` where `role` is `:parent` or `:child`, `name` is
`parent` or the SSH host, and `n` is the explicit count or `nothing`.
"""
function parse_placement_token(
        spec::AbstractString,
    )::NamedTuple{(:role, :name, :n), Tuple{Symbol, String, Union{Nothing, Int}}}
    return machine_to_placement_token(spec)
end

"""True when a CLI token looks like a local `.jl` script path, not an SSH host.

# Examples
```jldoctest
julia> using DistSSHRun

julia> DistSSHRun.DistSSHBase.looks_like_script_host("job.jl")
true

julia> DistSSHRun.DistSSHBase.looks_like_script_host("host1")
false
```
"""
function looks_like_script_host(token::AbstractString)::Bool
    h = String(token)
    endswith(lowercase(h), ".jl") && return true
    return false
end

"""
True when a CLI token looks like a local filesystem path (not `user@host`).

Rejects path-like tokens so `setup delete demos/foo.jl` fails early.

# Examples
```jldoctest
julia> using DistSSHRun

julia> DistSSHRun.looks_like_path_host("demos/foo.jl")
true

julia> DistSSHRun.looks_like_path_host("user@host")
false
```
"""
function looks_like_path_host(token::AbstractString)::Bool
    h = String(token)
    looks_like_script_host(h) && return true
    occursin('@', h) && return false
    (occursin('/', h) || occursin('\\', h)) && return true
    isfile(h) && return true
    return false
end

"""
Short, actionable summary for SSH / remote-shell failures.

Prefer this over dumping a full `ProcessFailedException` with a long `Cmd`.
A remote shell whose exit is not 255 adds a `help setup` line when the login
shell is non-POSIX. Exit 255 is SSH itself and is not probed.
"""
function summarize_ssh_error(err; stderr::AbstractString = "")::String
    return _append_remote_shell_hint_from_error(err, _summarize_ssh_error_text(err; stderr = stderr))
end

function _summarize_ssh_error_text(err; stderr::AbstractString = "")::String
    detail = strip(String(stderr))
    msg = sprint(showerror, err)
    blob = isempty(detail) ? msg : detail * "\n" * msg

    if occursin(r"(?i)bad configuration option:\s*usekeychain|usekeychain", blob)
        return "SSH config rejects UseKeychain (common with Homebrew OpenSSH). " *
            "Under `Host *` in ~/.ssh/config add `IgnoreUnknown UseKeychain`, " *
            "or put Apple's ssh first: PATH=\"/usr/bin:\$PATH\"."
    end
    if occursin(r"(?i)permission denied|no matching host key|host key verification failed", blob)
        return "SSH auth/host-key failed (BatchMode; no password prompt). " *
            "Fix: ssh-copy-id HOST  (or trust the host key once interactively)."
    end
    if occursin(r"(?i)could not resolve hostname|name or service not known|nodename nor servname", blob)
        return "SSH host not found (DNS / typo / missing SSH config Host alias)."
    end
    if occursin(r"(?i)connection timed out|operation timed out|connection refused", blob)
        return "SSH could not connect (timeout / refused). Check IP, VPN, and that the host is up."
    end
    if !isempty(detail)
        # First non-empty stderr line is usually the real OpenSSH message.
        for line in eachline(IOBuffer(detail))
            s = strip(line)
            isempty(s) && continue
            return _truncate_ssh_message(s)
        end
    end
    if occursin(r"ProcessExited\(255\)", msg) || occursin("[255]", msg)
        return "SSH failed (exit 255). Check: ssh -o BatchMode=yes -o ConnectTimeout=5 HOST echo ok"
    end
    return _truncate_ssh_message(msg)
end

function _truncate_ssh_message(msg::AbstractString; limit::Int = 220)::String
    s = replace(strip(String(msg)), r"\s+" => " ")
    length(s) <= limit && return s
    return s[1:prevind(s, limit)] * "…"
end
