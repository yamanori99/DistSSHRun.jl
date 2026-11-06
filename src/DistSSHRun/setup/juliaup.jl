# Align remote Julia via juliaup (`up` / check Fix hints).
# Channel math, status, and the juliaup process live in up/.


"""Print Fix lines for missing / mismatched remote Julia (check output)."""
function print_juliaup_align_fix!(
        host::AbstractString;
        kind::Symbol = :mismatch,
        channel::AbstractString = juliaup_channel(),
    )
    ch = String(channel)
    h = String(host)
    kit_payload_println("    Fix: $(cli_m_project()) up add $ch $(setup_cli_host_token(h))")
    kit_payload_println("         $(cli_m_project()) up update $ch $(setup_cli_host_token(h))")
    kit_payload_println("         $(cli_m_project()) up default $ch $(setup_cli_host_token(h))")
    kit_payload_println("         (or on $h: juliaup add $ch && juliaup update $ch && \\")
    kit_payload_println("          juliaup default $ch —")
    kit_payload_println("          \$HOME/.juliaup/bin/juliaup, /opt/homebrew/bin/juliaup,")
    kit_payload_println("          or /usr/local/bin/juliaup; changes host default Julia)")
    kit_payload_println("         No juliaup? install it first (see Requirements), or use --julia PATH /")
    kit_payload_println("         JULIA_DISTRIBUTED_EXE.")
    if kind === :mismatch
        kit_payload_println("         Or pass --ignore-julia-version to continue anyway.")
    end
    return nothing
end

"""`X.Y` and `X.Y-nightly` move. A named prerelease such as `1.14.0-alpha1` does not."""
function _juliaup_channel_moves(channel::AbstractString)::Bool
    ch = String(channel)
    occursin(r"^\d+\.\d+$", ch) && return true
    return endswith(ch, "-nightly")
end

"""Note when remotes landed on a newer patch than the kit parent (channel latest).

A moving channel says the parent is behind. A pinned channel says `juliaup add` may
have been treated as success without installing that channel. The success count stays.
"""
function print_juliaup_parent_patch_note!(
        remote_version::VersionNumber;
        local_version::VersionNumber = VERSION,
        channel::AbstractString = juliaup_channel(local_version),
    )
    juliaup_parent_behind_channel(local_version, remote_version) || return false
    ch = String(channel)
    if _juliaup_channel_moves(ch)
        warn("kit parent Julia $local_version is behind channel $ch latest on remotes ($remote_version)")
        kit_payload_println("    Tip: $(cli_m_project()) up update $ch $PARENT_HOST_NAME")
        kit_payload_println("         $(cli_m_project()) up default $ch $PARENT_HOST_NAME")
        kit_payload_println("         (or: juliaup update $ch && juliaup default $ch), then re-run workers.")
    else
        warn("pinned channel $ch may not be installed on the worker")
        kit_payload_println("    Check the result of `juliaup add $ch` on the worker.")
    end
    return true
end

"""One host line visible under `:progress` when juliaup is already on `channel`."""
function print_juliaup_already_on!(host::AbstractString, channel::AbstractString)
    msg = "  $(String(host)): already on $(String(channel))"
    with_kit_progress_suspended() do
        if kit_output_detail() || kit_output_progress()
            if kit_output_detail() && use_colors()
                printstyled(msg; color = :green)
                println()
            else
                println(msg)
            end
        end
    end
    _kit_log_writeln(msg)
    return nothing
end

"""
Align each target's juliaup default to `channel` (kit parent major.minor).

Targets may be SSH hosts and/or [`PARENT_HOST_NAME`](@ref) (`parent`). Requires
an existing `juliaup` (official `\$HOME/.juliaup/bin/juliaup` or macOS Homebrew
`/opt/homebrew/bin/juliaup` / `/usr/local/bin/juliaup`). Does not install
juliaup. Runs `add` → `update` → `default`. Confirm unless `confirm=false`.
Changing the default does not alter the Julia process already running this kit.
"""
function juliaup_align_remotes(
        hosts::Vector{String};
        channel::AbstractString = juliaup_channel(),
        confirm::Bool = true,
    )::NamedTuple
    ch = String(channel)
    if confirm && !kit_noninteractive()
        cancelled = with_kit_progress_suspended() do
            print_err("  This will run juliaup add/update/default $ch on each target.\n")
            println_fatal("  That changes the host default Julia.")
            println_fatal("  Targets: $(join(hosts, ", "))")
            println_fatal("  Needs juliaup at \$HOME/.juliaup/bin/juliaup or Homebrew")
            println_fatal("  (/opt/homebrew/bin/juliaup or /usr/local/bin/juliaup).")
            println_fatal("  The running kit process keeps its current Julia until restart.")
            println_fatal()
            kit_confirm("Type 'juliaup' to confirm: "; keyword = "juliaup") || begin
                println_fatal("Cancelled.")
                return true
            end
            println_fatal()
            return false
        end
        cancelled && return (; cancelled = true, succeeded = 0, failed = 0, hosts = HostResult[])
    end

    succeeded = 0
    failed = 0
    host_results = HostResult[]
    for host in hosts
        _setup_host_span!(host, :running)
        label = is_parent_host_name(host) ? PARENT_HOST_NAME : host
        try
            r = kit_spin!("  $label: ") do
                juliaup_align_host!(host; channel = ch)
            end
            if r.already
                print_juliaup_already_on!(label, ch)
            else
                kit_payload_ok("✓ Julia $(r.ver) (channel $ch)")
                kit_payload_println()
                if is_parent_host_name(host)
                    kit_payload_println("    Note: this process still runs Julia $VERSION until you restart.")
                else
                    ver = r.ver
                    ver isa VersionNumber || error("juliaup align returned no version")
                    print_juliaup_parent_patch_note!(ver; channel = ch)
                end
            end
            succeeded += 1
            push!(host_results, HostResult(label, true, "juliaup $ch"))
            _setup_host_span!(host, :ok)
        catch e
            detail = e isa ErrorException ? e.msg : sprint(showerror, e)
            report_remote_failure(e)
            if occursin("juliaup not found", detail) || occursin("127", detail)
                kit_payload_println("    Install juliaup on $label first (see Requirements), then retry.")
            end
            failed += 1
            push!(host_results, HostResult(label, false, detail))
            _setup_host_span!(host, :fail)
        end
    end
    return (; host_op_result(succeeded = succeeded, failed = failed)..., hosts = host_results)
end

"""
Run `juliaup update` on each target (installed channels; does not `default`).

Same hosts as `up` (`child:NAME` and/or `parent`). Confirm unless
`confirm=false`. Does not install juliaup.
"""
function juliaup_update_remotes(
        hosts::Vector{String};
        confirm::Bool = true,
    )::NamedTuple
    if confirm && !kit_noninteractive()
        cancelled = with_kit_progress_suspended() do
            print_err("  This will run juliaup update on each target.\n")
            println_fatal("  Installed channels refresh; the host default is unchanged.")
            println_fatal("  Targets: $(join(hosts, ", "))")
            println_fatal("  Needs juliaup at \$HOME/.juliaup/bin/juliaup or Homebrew")
            println_fatal("  (/opt/homebrew/bin/juliaup or /usr/local/bin/juliaup).")
            println_fatal("  The running kit process keeps its current Julia until restart.")
            println_fatal()
            kit_confirm("Type 'update' to confirm: "; keyword = "update") || begin
                println_fatal("Cancelled.")
                return true
            end
            println_fatal()
            return false
        end
        cancelled && return (; cancelled = true, succeeded = 0, failed = 0, hosts = HostResult[])
    end

    succeeded = 0
    failed = 0
    host_results = HostResult[]
    for host in hosts
        _setup_host_span!(host, :running)
        label = is_parent_host_name(host) ? PARENT_HOST_NAME : host
        try
            kit_spin!("  $label: ") do
                juliaup_update_host!(host)
            end
            kit_payload_ok("✓ juliaup update")
            kit_payload_println()
            succeeded += 1
            push!(host_results, HostResult(label, true, "juliaup update"))
            _setup_host_span!(host, :ok)
        catch e
            detail = e isa ErrorException ? e.msg : sprint(showerror, e)
            report_remote_failure(e)
            if occursin("juliaup not found", detail) || occursin("127", detail)
                kit_payload_println("    Install juliaup on $label first (see Requirements), then retry.")
            end
            failed += 1
            push!(host_results, HostResult(label, false, detail))
            _setup_host_span!(host, :fail)
        end
    end
    return (; host_op_result(succeeded = succeeded, failed = failed)..., hosts = host_results)
end

"""`*` row when juliaup marked one, otherwise the first kept row."""
function _juliaup_summary_row(
        rows::AbstractVector{<:AbstractString},
    )::Union{Nothing, String}
    isempty(rows) && return nothing
    for row in rows
        startswith(strip(row), "*") && return String(row)
    end
    return String(first(rows))
end

"""Channel, installed patch, and the update column (build suffix stripped).

The installed patch of a `*` row is [`DistSSHUp._juliaup_patch_from_status`](@ref).
"""
function _juliaup_summary_fields(row::AbstractString)
    installed = if startswith(strip(row), "*")
        DistSSHUp._juliaup_patch_from_status(row)
    else
        raw = split(strip(row))
        length(raw) < 2 ? "-" : String(first(split(String(raw[2]), '+'; limit = 2)))
    end
    parts = split(strip(row))
    if !isempty(parts) && parts[1] == "*"
        parts = parts[2:end]
    end
    channel = isempty(parts) ? "-" : String(parts[1])
    available = if length(parts) < 3
        "none"
    else
        String(first(split(String(parts[3]), '+'; limit = 2)))
    end
    return channel, installed, available
end

"""`same as parent`, `behind parent V`, `ahead of parent V`, or `parent unknown`.

`parent` is always `same as parent`. Other hosts compare patch strings as
`VersionNumber`. A missing or unparseable patch is `parent unknown`.
"""
function _juliaup_patch_relation(
        host::AbstractString,
        installed::AbstractString,
        parent_patch::AbstractString,
    )::String
    is_parent_host_name(host) && return "same as parent"
    parent_patch == "-" && return "parent unknown"
    installed == "-" && return "parent unknown"
    parent_v = tryparse(VersionNumber, String(parent_patch))
    installed_v = tryparse(VersionNumber, String(installed))
    (parent_v === nothing || installed_v === nothing) && return "parent unknown"
    installed_v == parent_v && return "same as parent"
    installed_v < parent_v && return "behind parent $parent_patch"
    return "ahead of parent $parent_patch"
end

"""One `up status` line for `host`.

`rows` are installed `juliaup status` lines. Empty rows are `(none)`.
The line names the channel, the installed patch, how that patch sits
against `parent_patch`, and the available update. It does not include the
juliaup build triplet.
"""
function juliaup_status_summary_line(
        host::AbstractString,
        rows::AbstractVector{<:AbstractString};
        parent_patch::AbstractString,
    )::String
    label = is_parent_host_name(host) ? PARENT_HOST_NAME : String(host)
    row = _juliaup_summary_row(rows)
    row === nothing && return "  $label: (none)"
    channel, installed, available = _juliaup_summary_fields(row)
    rel = _juliaup_patch_relation(label, installed, String(parent_patch))
    return "  $label: channel $channel, installed $installed, $rel, available $available"
end

"""
Run one juliaup verb on each target.

`verb` is `add`, `default`, `update`, or `status`. `add` and `default` need
`channel`. Confirm only for `default`, which changes the host default Julia.
"""
function juliaup_verb_remotes(
        hosts::Vector{String};
        verb::AbstractString,
        channel::Union{Nothing, AbstractString} = nothing,
        confirm::Bool = true,
    )::NamedTuple
    v = String(verb)
    ch = channel === nothing ? nothing : String(channel)
    if v == "default" && confirm && !kit_noninteractive()
        cancelled = with_kit_progress_suspended() do
            print_err("  This will run juliaup default $ch on each target.\n")
            println_fatal("  That changes the host default Julia.")
            println_fatal("  Targets: $(join(hosts, ", "))")
            println_fatal("  The running kit process keeps its current Julia until restart.")
            println_fatal()
            kit_confirm("Type 'default' to confirm: "; keyword = "default") || begin
                println_fatal("Cancelled.")
                return true
            end
            println_fatal()
            return false
        end
        cancelled && return (; cancelled = true, succeeded = 0, failed = 0, hosts = HostResult[])
    end

    succeeded = 0
    failed = 0
    host_results = HostResult[]
    for host in hosts
        _setup_host_span!(host, :running)
        label = is_parent_host_name(host) ? PARENT_HOST_NAME : host
        try
            if v == "status"
                lines = juliaup_status_lines(host; channel = ch, strict = true)
                parent_patch = DistSSHUp.juliaup_default_patch(PARENT_HOST_NAME)
                kit_payload_println(
                    juliaup_status_summary_line(host, lines; parent_patch = parent_patch),
                )
                if kit_output_detail()
                    for line in lines
                        kit_payload_println("  $label: $line")
                    end
                end
            else
                kit_spin!("  $label: ") do
                    if v == "add"
                        juliaup_add_host!(host, something(ch, ""))
                    elseif v == "default"
                        juliaup_default_host!(host, something(ch, ""))
                    elseif v == "update"
                        juliaup_update_host!(host; channel = ch)
                    else
                        error("unknown juliaup verb: $v")
                    end
                end
                kit_payload_ok("✓ juliaup $v$(ch === nothing ? "" : " $ch")")
                kit_payload_println()
            end
            succeeded += 1
            push!(host_results, HostResult(label, true, "juliaup $v"))
            _setup_host_span!(host, :ok)
        catch e
            detail = e isa ErrorException ? e.msg : sprint(showerror, e)
            report_remote_failure(e)
            if occursin("juliaup not found", detail) || occursin("127", detail)
                kit_payload_println("    Install juliaup on $label first (see Requirements), then retry.")
            end
            failed += 1
            push!(host_results, HostResult(label, false, detail))
            _setup_host_span!(host, :fail)
        end
    end
    return (; host_op_result(succeeded = succeeded, failed = failed)..., hosts = host_results)
end
