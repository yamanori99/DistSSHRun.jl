const _CollectSkip = Pair{String, String}

function _push_collect_skip!(skipped::Vector{_CollectSkip}, host::AbstractString, reason::AbstractString)
    push!(skipped, String(host) => String(reason))
    return nothing
end

function _print_collect_skip_summary!(skipped::Vector{_CollectSkip})
    isempty(skipped) && return nothing
    writeln_both("Collect skipped hosts:")
    for (host, reason) in skipped
        writeln_both("  $host: $reason")
    end
    writeln_both("")
    return nothing
end

"""
Recursively pull files under `local_root` from each host (**collect-missing** /
**collect-overwrite**).

- `merge=false`: skip relative paths that already exist locally.
- `merge=true`:  pull the whole tree with Tar (overwrites same-named files).

Uses the remote work root (`runs/<run_id>/src` after ship-tree) to map the local root onto each host.
Respects `--quiet` / `--progress` via kit printers (kit log still written when open).

`best_effort=false` (default): any host that cannot be collected fails the run.
`best_effort=true`: continue past skipped hosts; skipped hosts are listed at the end.
"""
function drive_collect_tree(
        local_root::AbstractString,
        host_names::Vector{String};
        merge::Bool = false,
        best_effort::Bool = false,
        project_root::AbstractString,
        path_anchor::AbstractString,
        julia::Union{Nothing, AbstractString} = nothing,
        run_id::Union{Nothing, AbstractString} = nothing,
    )
    repo_root = canonical_local_path(project_root)
    local_root = DistSSHRun.canonical_local_path(local_root)
    _error_collect_root_overlap(local_root, repo_root) && return (false, _CollectSkip[])
    print_header(merge ? cli_heading("collect-overwrite") : cli_heading("collect-missing"))
    writeln_both("")
    writeln_field("Local root", display_path(local_root, path_anchor))
    writeln_field(
        "Mode",
        merge ? "full sync (same-named files updated when remote differs)" :
            "missing paths only (existing local files left unchanged)",
    )
    writeln_field("Hosts", join(host_names, ", "))
    writeln_both("")

    if merge
        escaped = _collect_local_symlink_escape(local_root)
        if escaped !== nothing
            print_warn(
                "Warning: collect-overwrite refused because $escaped points outside $local_root.\n",
            )
            return (false, _CollectSkip[])
        end
    end

    shown_root = DistSSHRun._remote_work_layout_path(
        local_root, repo_root, host_names; run_id = run_id,
    )
    if shown_root != local_root
        writeln_field("Remote root", shown_root)
        writeln_both("")
    end

    skipped = _CollectSkip[]
    hosts_ok = 0
    for host in host_names
        write_both("  $host: ")
        try
            remote_root = DistSSHRun._remote_work_layout_path(
                local_root, repo_root, String[String(host)];
                run_id = run_id,
            )
            host_remote = ensure_remote_abs_path(host, remote_root)
            if host_remote === nothing
                reason = "cannot resolve remote root $(repr(remote_root))"
                writeln_both("(skip: $reason)")
                writeln_both("      hint: export DISTRIBUTED_REMOTE_PROJECT_ROOT=<abs path on SSH host>")
                _push_collect_skip!(skipped, host, reason)
                continue
            end
            host_remote = host_remote::String
            pq = DistSSHRun._remote_shell_path_word(host_remote)
            if !success(
                    pipeline(
                        DistSSHRun._host_sync_remote_shell_cmd(host, "test -d $pq");
                        stderr = devnull, stdout = devnull,
                    )
                )
                reason = "no directory on host at $host_remote"
                writeln_both("(skip: $reason)")
                writeln_both("      hint: export DISTRIBUTED_REMOTE_PROJECT_ROOT=<repo root on SSH host>")
                _push_collect_skip!(skipped, host, reason)
                continue
            end

            remote_files = collect_tree_remote_files_ssh(host, host_remote)
            if isempty(remote_files)
                writeln_both("(remote root empty or no files found)")
                hosts_ok += 1
                continue
            end

            julia_bin = DistSSHRun._pull_remote_julia(host, julia)
            if merge
                DistSSHRun._pull_tar_tree!(
                    host, host_remote, local_root; julia_bin = julia_bin,
                )
                n = length(remote_files)
                print_ok("✓ (synced $n remote file$(n == 1 ? "" : "s"))")
                writeln_both("")
                hosts_ok += 1
            else
                need = String[
                    rel for (_, rel) in remote_files
                        if !isfile(joinpath(local_root, rel))
                ]
                if isempty(need)
                    writeln_both("(nothing new — all remote files exist locally; use --collect-overwrite to replace)")
                    hosts_ok += 1
                    continue
                end
                sort!(need)
                safe = String[]
                unsafe_skipped = 0
                for rel in need
                    if startswith(rel, "..") || _collect_dest_escapes_root(local_root, rel)
                        unsafe_skipped += 1
                        print_warn(
                            "Warning: skipping $rel; it would write outside $local_root.\n",
                        )
                        continue
                    end
                    push!(safe, rel)
                end
                if isempty(safe)
                    reason = if unsafe_skipped > 0
                        "nothing safe to collect ($unsafe_skipped path$(unsafe_skipped == 1 ? "" : "s") escaped the root)"
                    else
                        "nothing safe to collect"
                    end
                    writeln_both("($reason)")
                    _push_collect_skip!(skipped, host, reason)
                    continue
                end
                need = safe
                DistSSHRun._pull_tar_rels!(
                    host, host_remote, local_root, need; julia_bin = julia_bin,
                )
                n = length(need)
                print_ok("✓ ($n file$(n == 1 ? "" : "s"))")
                writeln_both("")
                hosts_ok += 1
            end
        catch e
            reason = sprint(showerror, e)
            _push_collect_skip!(skipped, host, reason)
            print_progress_err("✗ $reason")
            writeln_both("")
            continue
        end
    end
    writeln_both("")
    _print_collect_skip_summary!(skipped)
    ok = true
    if !isempty(skipped)
        if !best_effort
            ok = false
            println_fatal("Collect failed: one or more hosts were skipped (see list above).")
            println_fatal("Pass --best-effort on drive collect to continue past skipped hosts.")
        elseif hosts_ok == 0
            ok = false
            println_fatal("Collect failed: every host was skipped (see list above).")
        end
    end
    return (ok, skipped)
end