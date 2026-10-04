# Align remote Julia via juliaup (`up` / check Fix hints).
# Channel math, status, and the juliaup process live in DistSSHUp.


"""Print Fix lines for missing / mismatched remote Julia (check output)."""
function print_juliaup_align_fix!(
        host::AbstractString;
        kind::Symbol = :mismatch,
        channel::AbstractString = juliaup_channel(),
    )
    ch = String(channel)
    h = String(host)
    kit_println("    Fix: julia --project=. -m DistSSHKit up $(setup_cli_host_token(h))")
    kit_println("         (or on $h: juliaup add $ch && juliaup update $ch && \\")
    kit_println("          juliaup default $ch —")
    kit_println("          \$HOME/.juliaup/bin/juliaup, /opt/homebrew/bin/juliaup,")
    kit_println("          or /usr/local/bin/juliaup; changes host default Julia)")
    kit_println("         No juliaup? install it first (see Requirements), or use --julia PATH /")
    kit_println("         JULIA_DISTRIBUTED_EXE.")
    if kind === :mismatch
        kit_println("         Or pass --ignore-julia-version to continue anyway.")
    end
    return nothing
end

"""Note when remotes landed on a newer patch than the kit parent (channel latest)."""
function print_juliaup_parent_patch_note!(
        remote_version::VersionNumber;
        local_version::VersionNumber = VERSION,
        channel::AbstractString = juliaup_channel(local_version),
    )
    juliaup_parent_behind_channel(local_version, remote_version) || return false
    ch = String(channel)
    warn("kit parent Julia $local_version is behind channel $ch latest on remotes ($remote_version)")
    kit_println("    Tip: julia --project=. -m DistSSHKit up $PARENT_HOST_NAME")
    kit_println("         (or: juliaup update $ch && juliaup default $ch), then re-run workers.")
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

    remote_sh = _juliaup_align_remote_sh(ch)
    succeeded = 0
    failed = 0
    host_results = HostResult[]
    for host in hosts
        _setup_host_span!(host, :running)
        err_buf = IOBuffer()
        out_buf = IOBuffer()
        try
            if is_parent_host_name(host)
                r = kit_spin!("  $PARENT_HOST_NAME: ") do
                    _juliaup_align_local!(ch)
                end
                if r.changed
                    print_ok("✓ Julia $(r.ver) (channel $ch)")
                    kit_println()
                    kit_println("    Note: this process still runs Julia $VERSION until you restart.")
                else
                    print_juliaup_already_on!(PARENT_HOST_NAME, ch)
                end
                succeeded += 1
                push!(host_results, HostResult(PARENT_HOST_NAME, true, "juliaup $ch"))
                _setup_host_span!(host, :ok)
                continue
            end
            align_out = kit_spin!("  $host: ") do
                proc = run(
                    pipeline(
                        ignorestatus(_host_sync_remote_shell_cmd(host, remote_sh));
                        stdout = out_buf,
                        stderr = err_buf,
                    );
                    wait = true,
                )
                if proc.exitcode != 0
                    msg = strip(String(take!(err_buf)))
                    isempty(msg) && (msg = strip(String(take!(out_buf))))
                    isempty(msg) && (msg = "juliaup align exit $(proc.exitcode)")
                    error(first(split(msg, '\n')))
                end
                return strip(String(take!(out_buf)))
            end
            if align_out == "already"
                print_juliaup_already_on!(host, ch)
            else
                clear_detect_julia_path_cache!(host)
                path = detect_julia_path(host)
                path === nothing && error("Julia not found after juliaup align")
                ver = _remote_julia_version_setup_ssh(host, path)
                ver === nothing && error("Julia --version unparseable after juliaup align")
                if julia_version_mismatch_kind(VERSION, ver) == :minor
                    error("still mismatched after align: local $(VERSION), remote $ver")
                end
                print_ok("✓ Julia $ver (channel $ch)")
                kit_println()
                print_juliaup_parent_patch_note!(ver; channel = ch)
            end
            succeeded += 1
            push!(host_results, HostResult(host, true, "juliaup $ch"))
            _setup_host_span!(host, :ok)
        catch e
            detail = strip(String(take!(err_buf)))
            report_remote_failure(e; stderr = detail)
            combined = isempty(detail) ? sprint(showerror, e) : detail
            if occursin("juliaup not found", combined) || occursin("127", combined)
                kit_println("    Install juliaup on $host first (see Requirements), then retry.")
            end
            failed += 1
            push!(host_results, HostResult(host, false, combined))
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

    remote_sh = _juliaup_update_remote_sh()
    succeeded = 0
    failed = 0
    host_results = HostResult[]
    for host in hosts
        _setup_host_span!(host, :running)
        err_buf = IOBuffer()
        out_buf = IOBuffer()
        try
            if is_parent_host_name(host)
                kit_spin!("  $PARENT_HOST_NAME: ") do
                    _juliaup_update_local!()
                end
                print_ok("✓ juliaup update")
                kit_println()
                succeeded += 1
                push!(host_results, HostResult(PARENT_HOST_NAME, true, "juliaup update"))
                _setup_host_span!(host, :ok)
                continue
            end
            kit_spin!("  $host: ") do
                proc = run(
                    pipeline(
                        ignorestatus(_host_sync_remote_shell_cmd(host, remote_sh));
                        stdout = out_buf,
                        stderr = err_buf,
                    );
                    wait = true,
                )
                if proc.exitcode != 0
                    msg = strip(String(take!(err_buf)))
                    isempty(msg) && (msg = strip(String(take!(out_buf))))
                    isempty(msg) && (msg = "juliaup update exit $(proc.exitcode)")
                    error(first(split(msg, '\n')))
                end
                return nothing
            end
            print_ok("✓ juliaup update")
            kit_println()
            succeeded += 1
            push!(host_results, HostResult(host, true, "juliaup update"))
            _setup_host_span!(host, :ok)
        catch e
            detail = strip(String(take!(err_buf)))
            report_remote_failure(e; stderr = detail)
            combined = isempty(detail) ? sprint(showerror, e) : detail
            if occursin("juliaup not found", combined) || occursin("127", combined)
                kit_println("    Install juliaup on $host first (see Requirements), then retry.")
            end
            failed += 1
            push!(host_results, HostResult(host, false, combined))
            _setup_host_span!(host, :fail)
        end
    end
    return (; host_op_result(succeeded = succeeded, failed = failed)..., hosts = host_results)
end
