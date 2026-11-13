# Runner-only preflight checks (git parity).

function check_git_hashes(hosts::Vector{String}, proj_dir::String)
    remote_root = resolve_remote_project_root(proj_dir)
    env_remote = strip(get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", ""))

    local_hash = get_local_git_hash(proj_dir)
    if local_hash === nothing
        write_both("  ")
        if !_host_tool_present("git")
            missing = explain_host_tool_missing("git")
            head, rest... = split(missing, '\n'; keepempty = false)
            print_progress_warn("⚠ $head")
            writeln_both("")
            for line in rest
                writeln_both("  $line")
            end
        else
            print_progress_warn("⚠ Could not get local git hash (not a git repo?)")
            writeln_both("")
        end
        if !isempty(hosts)
            writeln_both("  Remote git parity cannot be verified without a local git commit.")
            writeln_both("")
            return false, String[], copy(hosts)
        end
        return true, String[], String[]
    end

    writeln_both("  Local: $(local_hash[1:8])...")
    if !isempty(hosts) || !isempty(env_remote)
        writeln_both("  Remote project root: $remote_root")
    end

    mismatches = String[]
    unverifiable = String[]
    for host in hosts
        remote_hash = get_remote_git_hash(host, remote_root)
        if remote_hash === nothing
            write_both("  $host: ")
            print_progress_err("✗ Could not get git hash (not a git repo?)")
            writeln_both("")
            push!(unverifiable, host)
        elseif remote_hash != local_hash
            write_both("  $host: ")
            print_progress_err("✗ $(remote_hash[1:8])... (MISMATCH)")
            writeln_both("")
            push!(mismatches, host)
        else
            write_both("  $host: ")
            print_ok("✓ $(remote_hash[1:8])...")
            writeln_both("")
        end
    end

    ok = isempty(mismatches) && isempty(unverifiable)
    return ok, mismatches, unverifiable
end
