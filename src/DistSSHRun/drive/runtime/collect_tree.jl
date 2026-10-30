"""
Recursively pull files under `local_root` from each host (**collect-missing** /
**collect-overwrite**).

- `merge=false`: skip relative paths that already exist locally.
- `merge=true`:  pull the whole tree with Tar (overwrites same-named files).

Uses the remote work root (`runs/<run_id>/src` after ship-tree) to map the local root onto each host.
Respects `--quiet` / `--progress` via kit printers (kit log still written when open).
"""
function drive_collect_tree(
        local_root::AbstractString,
        host_names::Vector{String};
        merge::Bool = false,
        strict::Bool = false,
        project_root::AbstractString,
        path_anchor::AbstractString,
    )
    repo_root = canonical_local_path(project_root)
    local_root = DistSSHRun.canonical_local_path(local_root)
    _error_collect_root_overlap(local_root, repo_root) && return false
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
            return false
        end
    end

    shown_root = DistSSHRun._remote_work_layout_path(local_root, repo_root, host_names)
    if shown_root != local_root
        writeln_field("Remote root", shown_root)
        writeln_both("")
    end

    ok = true
    for host in host_names
        write_both("  $host: ")
        try
            remote_root = DistSSHRun._remote_work_layout_path(
                local_root, repo_root, String[String(host)],
            )
            host_remote = ensure_remote_abs_path(host, remote_root)
            if host_remote === nothing
                writeln_both("(skip: cannot resolve remote root $(repr(remote_root)))")
                writeln_both("      hint: export DISTRIBUTED_REMOTE_PROJECT_ROOT=<abs path on SSH host>")
                strict && (ok = false)
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
                writeln_both("(skip: no directory on host at $host_remote)")
                writeln_both("      hint: export DISTRIBUTED_REMOTE_PROJECT_ROOT=<repo root on SSH host>")
                strict && (ok = false)
                continue
            end

            remote_files = collect_tree_remote_files_ssh(host, host_remote)
            if isempty(remote_files)
                writeln_both("(remote root empty or no files found)")
                continue
            end

            if merge
                DistSSHRun._pull_tar_tree!(host, host_remote, local_root)
                n = length(remote_files)
                print_ok("✓ (synced $n remote file$(n == 1 ? "" : "s"))")
                writeln_both("")
            else
                need = String[
                    rel for (_, rel) in remote_files
                        if !isfile(joinpath(local_root, rel))
                ]
                if isempty(need)
                    writeln_both("(nothing new — all remote files exist locally; use --collect-overwrite to replace)")
                    continue
                end
                sort!(need)
                safe = String[]
                for rel in need
                    if startswith(rel, "..") || _collect_dest_escapes_root(local_root, rel)
                        ok = false
                        print_warn(
                            "Warning: skipping $rel; it would write outside $local_root.\n",
                        )
                        continue
                    end
                    push!(safe, rel)
                end
                if isempty(safe)
                    writeln_both("(nothing safe to collect)")
                    continue
                end
                need = safe
                DistSSHRun._pull_tar_rels!(host, host_remote, local_root, need)
                n = length(need)
                print_ok("✓ ($n file$(n == 1 ? "" : "s"))")
                writeln_both("")
            end
        catch e
            ok = false
            print_progress_err("✗ $(sprint(showerror, e))")
            writeln_both("")
        end
    end
    writeln_both("")
    if !ok
        println_fatal("(some hosts failed; exit 1)")
    end
    return ok
end
