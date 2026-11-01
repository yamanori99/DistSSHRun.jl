# Clone / delete / instantiate / cleanup / rsync CLI ops (shared display + counts).

remote_dir_exists(host::String, remote_path::String)::Bool =
    _remote_dir_exists(host, remote_path)

ensure_remote_dir(host::String, remote_path::String)::Bool =
    _ensure_remote_dir(host, remote_path)

"""
    rsync_push_to_remotes(hosts, remote_path, project; path_anchor=project)

Ship the git file list as a tar into `remote_path/runs/<run_id>/src/` on each
host (`setup --ship-tree`). The name is historical; this is not rsync.

Returns `(cancelled, succeeded, failed)`:
- `cancelled=true` when the user did not confirm
- otherwise per-host ship outcomes (`succeeded` / `failed` counts)
"""
function rsync_push_to_remotes(
        hosts::Vector{String},
        remote_path::String,
        project::AbstractString;
        path_anchor::AbstractString = project,
        allow_external_symlinks::Bool = false,
    )::NamedTuple
    raw = ship_project_to_hosts!(
        hosts,
        project,
        remote_path;
        confirm = true,
        report = true,
        path_anchor = path_anchor,
        allow_external_symlinks = allow_external_symlinks,
    )
    ok = count(hr -> hr.ok, raw.host_results)
    failed = count(hr -> !hr.ok, raw.host_results)
    return host_op_result(
        cancelled = raw.cancelled,
        succeeded = ok,
        failed = failed,
    )
end

# Shell helpers: missing run.toml is allowed; a present file must be owned.
# Delete passes `ship` and scans only `<root>/runs/<run_id>/run.toml`. A
# missing `runs/` is not a stamp tree. Prune omits that mode and walks its
# candidate recursively, including nested stamps. Textual check approximates
# `_kit_run_toml_owned` after a successful `TOML.parse`: top-level ownership
# fields, complete quoted strings, and well-formed table headers. Scan errors
# and newline paths fail closed.
function _remote_run_toml_owned_check_sh()::String
    return """
        _dsk_run_toml_owned() {
          _f=\$1
          [ -f "\$_f" ] || return 0
          awk '
            BEGIN { s = 0; w = 0; k = 0; top = 1; bad = 0 }
            /^[\\t ]*#/ { next }
            /^[\\t ]*\$/ { next }
            /^\\[/ {
              top = 0
              if (\$0 !~ /^\\[[^\\]]+\\]\$/) { bad = 1; exit }
              next
            }
            top == 1 {
              if (\$0 ~ /^schema = 1\$/) { s = 1; next }
              if (\$0 ~ /^writer = "DistSSHRun [^"]*"\$/) { w = 1; next }
              if (\$0 ~ /^writer = "DistSSHRun /) { bad = 1; exit }
              if (\$0 ~ /^kind = "(go|drive|ride|pipeline|ship)"\$/) { k = 1; next }
              if (\$0 ~ /^[A-Za-z_][A-Za-z0-9_]* = /) next
              bad = 1
              exit
            }
            {
              if (\$0 ~ /^[A-Za-z_][A-Za-z0-9_]* = /) next
              bad = 1
              exit
            }
            END { if (bad) exit 1; exit (s && w && k) ? 0 : 1 }
          ' "\$_f"
        }
        # `_ship` 1: only runs/<run_id>/run.toml. Both the newline check and
        # the list use this predicate.
        _dsk_find_stamps() {
          _dsk_find_root=\$1
          _dsk_find_ship=\$2
          shift 2
          if [ "\$_dsk_find_ship" = 1 ]; then
            find "\$_dsk_find_root" -mindepth 2 -maxdepth 2 -type f -name run.toml "\$@"
          else
            find "\$_dsk_find_root" -type f -name run.toml "\$@"
          fi
        }
        _dsk_first_unowned_stamp() {
          _root=\$1
          _ship=0
          _scan="\$_root"
          if [ "\${2-}" = ship ]; then
            _ship=1
            _scan="\$_root/runs"
            # Missing runs/ is an older tree, not a failed scan.
            if [ ! -d "\$_scan" ]; then
              return 0
            fi
          fi
          # Same newline refusal as remote input hashing: newline paths break
          # line-oriented scans, so treat them as unowned (fail closed).
          _nl=\$(_dsk_find_stamps "\$_scan" "\$_ship" -path '*
    *' -print -quit 2>/dev/null) || {
            printf '%s\\n' "\$_root"
            return 0
          }
          if [ -n "\$_nl" ]; then
            printf '%s\\n' "\$_nl"
            return 0
          fi
          _list=\$(mktemp) || {
            printf '%s\\n' "\$_root"
            return 0
          }
          if ! _dsk_find_stamps "\$_scan" "\$_ship" >"\$_list" 2>/dev/null; then
            rm -f "\$_list"
            printf '%s\\n' "\$_root"
            return 0
          fi
          _bad=
          while IFS= read -r _stamp || [ -n "\$_stamp" ]; do
            [ -n "\$_stamp" ] || continue
            if [ ! -f "\$_stamp" ] || ! _dsk_run_toml_owned "\$_stamp"; then
              _bad=\$_stamp
              break
            fi
          done <"\$_list"
          rm -f "\$_list"
          if [ -n "\$_bad" ]; then
            printf '%s\\n' "\$_bad"
            return 0
          fi
        }
        _dsk_assert_run_leaves_owned() {
          _root=\$1
          _bad=\$(_dsk_first_unowned_stamp "\$_root" ship)
          if [ -n "\$_bad" ]; then
            printf 'refusing to delete unowned run leaf %s\\n' "\$(dirname "\$_bad")" >&2
            return 1
          fi
          return 0
        }
        """
end

"""Remote `sh` that removes `remote_path` unless it is that host's home, `/`, or depot.

The final path component must not be a symlink. Intermediate symlinks stay,
so `cd -P` / `pwd -P` can resolve them. The `test -L` check and `rm` are one
script. Flags are `rm -rf` only (BSD rm on macOS).
"""
function _remote_delete_shell(remote_path::AbstractString)::String
    pq = _remote_shell_path_word(remote_path)
    # `$pq` is its own word. A double-quoted echo would treat its quotes as
    # text and run `$(...)` in the path.
    return """
    $(_remote_run_toml_owned_check_sh())
    if test -L $pq; then
      printf 'refusing to delete symlink %s\\n' $pq >&2
      exit 1
    fi
    if test -e $pq; then
      _distssh_target=\$(cd -P $pq && pwd -P) || exit 1
      _distssh_home=\$(cd -P ~ && pwd -P) || exit 1
      if [ "\$_distssh_target" = "\$_distssh_home" ] || [ "\$_distssh_target" = / ]; then
        printf 'refusing to delete %s\\n' "\$_distssh_target" >&2
        exit 1
      fi
      if test -d "\$_distssh_home/.julia"; then
        _distssh_depot=\$(cd -P "\$_distssh_home/.julia" && pwd -P) || exit 1
        if [ "\$_distssh_target" = "\$_distssh_depot" ]; then
          printf 'refusing to delete %s\\n' "\$_distssh_depot" >&2
          exit 1
        fi
      fi
      _dsk_assert_run_leaves_owned "\$_distssh_target" || exit 1
    fi
    rm -rf $pq 2>/dev/null
    if test -e $pq; then
      chmod -R u+rwX $pq 2>/dev/null
      rm -rf $pq
    fi
    """
end

"""
Delete remote repositories.

Returns `(cancelled, succeeded, failed, hosts)`. Caller should use
[`finish_host_op!`](@ref) so partial failure is not reported as success.
Pass `confirm=false` to skip the typed `delete` prompt. `-y` /
`DISTSSHKIT_YES` do not skip it. `setup --delete` sets `confirm=false`
only after `--confirm-path` matches, or after the typed `delete` prompt.
"""
function delete_remotes(
        hosts::Vector{String},
        remote_path::String;
        confirm::Bool = true,
    )::NamedTuple
    _checked_remote_dest(remote_path)
    _refuse_depot_target(remote_path)
    if confirm
        cancelled = with_kit_progress_suspended() do
            print_err("  This will DELETE repositories on all hosts via SSH.\n")
            println_fatal("  Remote path: $remote_path")
            println_fatal("  Hosts: $(join(hosts, ", "))")
            println_fatal("  Note: pass `child:NAME` for SSH hosts; `parent` only with up.")
            println_fatal()
            kit_confirm("Type 'delete' to confirm: "; keyword = "delete") || begin
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
        err_buf = IOBuffer()
        try
            kit_spin!("  $host: ") do
                read(
                    pipeline(
                        _host_sync_remote_shell_cmd(host, _remote_delete_shell(remote_path));
                        stderr = err_buf,
                    ),
                    String,
                )
                return nothing
            end
            print_ok("✓")
            kit_println()
            succeeded += 1
            push!(host_results, HostResult(host, true, "deleted"))
            _setup_host_span!(host, :ok)
        catch e
            detail = strip(String(take!(err_buf)))
            report_remote_failure(e; stderr = detail)
            failed += 1
            msg = isempty(detail) ? sprint(showerror, e) : detail
            push!(host_results, HostResult(host, false, msg))
            _setup_host_span!(host, :fail)
        end
    end
    return (; host_op_result(succeeded = succeeded, failed = failed)..., hosts = host_results)
end

"""
Clone repository on remote hosts. Refuses if remote_path already has files.

Returns `(cancelled, succeeded, failed, hosts)`.
Pass `confirm=false` to skip the proceed prompt (CLI `-y` / API `session.yes`).

Runs `git clone` **on each remote**. Private URLs need credentials **on that host**
(deploy key or HTTPS token), not the kit parent's agent.
"""
function clone_to_remotes(
        hosts::Vector{String},
        remote_path::String,
        clone_url::String;
        confirm::Bool = true,
    )::NamedTuple
    _checked_remote_dest(remote_path)
    if confirm && !kit_noninteractive()
        cancelled = with_kit_progress_suspended() do
            println_fatal("  Repository: $clone_url")
            println_fatal("  Remote path: $remote_path")
            println_fatal("  Hosts: $(join(hosts, ", "))")
            println_fatal()
            print_warn("  Safety: refuses if the remote path already has any files.\n")
            println_fatal("  To replace an existing tree, run `setup --delete` first, then `--clone`.")
            println_fatal()
            kit_confirm("Proceed? [y/N]: ") || begin
                println_fatal("Cancelled.")
                return true
            end
            println_fatal()
            return false
        end
        cancelled && return (; cancelled = true, succeeded = 0, failed = 0, hosts = HostResult[])
    end

    clone_sh = _remote_git_clone_sh(remote_path, clone_url)
    succeeded = 0
    failed = 0
    host_results = HostResult[]
    for host in hosts
        _setup_host_span!(host, :running)
        out_buf = IOBuffer()
        err_buf = IOBuffer()
        try
            outcome = kit_spin!("  $host: ") do
                st, detail = _remote_dest_probe(host, remote_path)
                if st === :error
                    return (:probe_fail, "could not inspect remote path: $detail")
                end
                if st === :nonempty
                    return (:busy, remote_dest_busy_message(host, remote_path))
                end
                if st === :missing && !_ensure_remote_clone_dest(host, remote_path)
                    return (:mkdir_fail, "could not create remote clone path")
                end
                # An existing empty directory keeps its mode. `umask` does not
                # change it, and a default ACL can override `mkdir -m`.
                refusal = _remote_clone_dest_refusal(host, remote_path)
                if refusal !== nothing
                    st === :missing && _remove_empty_remote_dir(host, remote_path)
                    return (:mode_fail, refusal)
                end
                run(
                    pipeline(
                        _host_sync_remote_shell_cmd(host, clone_sh);
                        stdout = out_buf,
                        stderr = err_buf,
                    )
                )
                return (:ok, "")
            end
            if outcome[1] !== :ok
                print_err("✗ $(outcome[2])")
                println()
                failed += 1
                push!(host_results, HostResult(host, false, outcome[2]))
                _setup_host_span!(host, :fail)
                continue
            end
            print_ok("✓")
            kit_println()
            succeeded += 1
            push!(host_results, HostResult(host, true, "cloned"))
            _setup_host_span!(host, :ok)
        catch e
            detail = _captured_output_tail(String(take!(out_buf)), String(take!(err_buf)))
            report_remote_failure(e; stderr = detail)
            failed += 1
            msg = isempty(detail) ? sprint(showerror, e) : detail
            push!(host_results, HostResult(host, false, msg))
            _setup_host_span!(host, :fail)
        end
    end
    return (; host_op_result(succeeded = succeeded, failed = failed)..., hosts = host_results)
end

"""Create `remote_path` with mode `755`, then drop group and other write.

`mkdir -m` is the requested mode. `chmod go-w` clears write again when a
default ACL added it. The caller still checks the mode before cloning.
"""
function _ensure_remote_clone_dest(host::String, remote_path::String)::Bool
    pq = _remote_shell_path_word(remote_path)
    try
        run(
            pipeline(
                _host_sync_remote_shell_cmd(host, "mkdir -p -m 755 $pq && chmod go-w $pq");
                stderr = devnull,
                stdout = devnull,
            ),
        )
        return true
    catch e
        _rethrow_missing_host_tool(e)
        DistSSHBase._throw_if_nonposix_shell(host, e)
        return false
    end
end

"""`nothing` when `remote_path` is a private directory. Otherwise the refusal."""
function _remote_clone_dest_refusal(
        host::AbstractString,
        remote_path::AbstractString,
    )::Union{Nothing, String}
    mode = _remote_project_mode(String(host), remote_path)
    refusal = _remote_writable_project_refusal(host, mode)
    refusal !== nothing && return refusal
    mode.kind === :missing || return nothing
    return "$host: could not read the project mode\nSee help setup."
end

"""Remove an empty directory this clone created after a mode refusal."""
function _remove_empty_remote_dir(host::AbstractString, remote_path::AbstractString)::Nothing
    pq = _remote_shell_path_word(remote_path)
    try
        run(
            pipeline(
                _host_sync_remote_shell_cmd(String(host), "rmdir $pq");
                stdout = devnull,
                stderr = devnull,
            ),
        )
    catch e
        _rethrow_missing_host_tool(e)
    end
    return nothing
end

"""Parent of a remote clone destination, or `nothing` when it is already `/` or `~`."""
function _remote_clone_parent(remote_path::AbstractString)::Union{Nothing, String}
    path = rstrip(strip(String(remote_path)), '/')
    parent = dirname(path)
    (isempty(parent) || parent == path || parent == "." || parent == "/") && return nothing
    occursin(r"^~[^/]*$", parent) && return nothing
    return parent
end

"""
Kill stale Julia worker processes on localhost and remote hosts.

Returns `(cancelled=false, succeeded, failed, hosts)` for the SSH hosts only
(localhost cleanup is always attempted and not counted as a remote failure).
"""
function cleanup_remote_workers(hosts::Vector{String})::NamedTuple
    kit_spin!("  localhost: ") do
        _pkill_local_julia_workers!()
        return nothing
    end
    print_ok("✓")
    kit_println()

    n = length(hosts)
    oks = fill(false, n)
    kit_spin!("  Cleaning remotes ($(length(hosts))) ") do
        map_host_jobs(hosts) do i, host
            _setup_host_span!(host, :running)
            okh = _pkill_remote_julia_workers!(host)
            oks[i] = okh
            _setup_host_span!(host, okh ? :ok : :fail)
        end
        return nothing
    end
    kit_println()

    succeeded = 0
    failed = 0
    host_results = HostResult[]
    for i in 1:n
        host = hosts[i]
        if oks[i]
            ok("$host: done")
            succeeded += 1
            push!(host_results, HostResult(host, true, "cleaned"))
        else
            fail("$host: SSH unreachable")
            failed += 1
            push!(host_results, HostResult(host, false, "SSH unreachable"))
        end
    end
    return (; host_op_result(succeeded = succeeded, failed = failed)..., hosts = host_results)
end

"""
Run `pkg_e` on remote hosts (parallel) with `--project` at `remote_path`.

`pkg_e` is the full `julia -e` program (it loads `Pkg` itself).
Returns `(cancelled=false, succeeded, failed)`.
Private git deps need a deploy key or HTTPS token on the remote. Uses
`JULIA_PKG_USE_CLI_GIT=true` so Pkg prefers the `git` CLI over LibGit2.
"""
function _pkg_e_on_remotes(
        hosts::Vector{String},
        julia_path::String,
        remote_path::String,
        project::AbstractString;
        path_anchor::AbstractString = project,
        pkg_e::AbstractString,
        spin_label::AbstractString,
    )::NamedTuple
    kit_println("  Local project: $(cli_project_disp(project, path_anchor))")
    kit_println("  Remote --project: $remote_path")
    kit_println()

    for host in hosts
        kit_println("  $host: queued")
    end

    pq = _remote_shell_path_word(remote_path)
    n = length(hosts)
    oks = fill(false, n)
    fail_msgs = fill("", n)
    kit_spin!("  $spin_label ($(length(hosts)) hosts) ") do
        map_host_jobs(hosts) do i, host
            _setup_host_span!(host, :running)
            host_julia = nothing
            ssh_msg = nothing
            try
                host_julia = julia_path == "auto" ? detect_julia_path(host) : julia_path
            catch e
                e isa ArgumentError || rethrow()
                ssh_msg = e.msg
            end
            if ssh_msg isa String
                oks[i] = false
                fail_msgs[i] = ssh_msg
            elseif host_julia === nothing
                oks[i] = false
                fail_msgs[i] = "Julia not found"
            else
                jb = _remote_shell_path_word(host_julia)
                # Prefer git CLI (ssh-agent / SSH config) over LibGit2 credentials UI.
                cmd = "JULIA_PKG_USE_CLI_GIT=true $jb --project=$pq --startup-file=no -e " *
                    posix_quote(String(pkg_e))
                out = IOBuffer()
                err = IOBuffer()
                try
                    proc = run(
                        pipeline(
                            ignorestatus(_host_sync_remote_shell_cmd(host, cmd));
                            stdout = out,
                            stderr = err,
                        );
                        wait = true,
                    )
                    if proc.exitcode == 0
                        oks[i] = true
                    else
                        oks[i] = false
                        msg = strip(String(take!(err)))
                        isempty(msg) && (msg = strip(String(take!(out))))
                        shown = isempty(msg) ? "exit $(proc.exitcode)" : first(split(msg, '\n'))
                        code = proc.exitcode isa Integer ? Int(proc.exitcode) : 1
                        fail_msgs[i] = DistSSHBase._append_remote_shell_hint(host, code, shown)
                    end
                catch e
                    oks[i] = false
                    fail_msgs[i] = sprint(showerror, e)
                end
            end
            _setup_host_span!(host, oks[i] ? :ok : :fail)
        end
        return nothing
    end
    kit_println()

    succeeded = 0
    failed = 0
    host_results = HostResult[]
    for i in 1:n
        host = hosts[i]
        if oks[i]
            ok("$host: done")
            succeeded += 1
            push!(host_results, HostResult(host, true, "done"))
        else
            fail("$host: failed")
            msg = fail_msgs[i]
            !isempty(msg) && kit_println("    $msg")
            if occursin("credential", lowercase(msg)) || occursin("Permission denied", msg) ||
                    occursin("failed to clone", lowercase(msg))
                kit_println("    Hint: remote needs a deploy key or HTTPS token for private deps.")
                kit_println("          (JULIA_PKG_USE_CLI_GIT is already set for this step)")
            end
            failed += 1
            push!(host_results, HostResult(host, false, isempty(msg) ? "failed" : msg))
        end
    end
    return (; cancelled = false, succeeded, failed, hosts = host_results)
end

"""
Julia `-e` program for remote instantiate.

The worker stops, and names `help setup`, when no registry is reachable,
when `Pkg.is_manifest_current` is not `true` (no `project_hash` included),
or when Manifest `julia_version` is missing or its minor differs from that
Julia. Otherwise it instantiates the Manifest and does not update registries.
"""
function _instantiate_remote_e()::String
    return join(
        (
            "using Pkg",
            "using TOML",
            "regs = Pkg.Registry.reachable_registries()",
            "if isempty(regs)",
            "    error(\"no reachable package registries. See help setup.\")",
            "end",
            "project = Base.active_project()",
            "if project === nothing",
            "    error(\"no active project. See help setup.\")",
            "end",
            "project_dir = isfile(project) ? dirname(project) : project",
            "if Pkg.is_manifest_current(project_dir) !== true",
            "    error(\"Manifest is not current with the project. See help setup.\")",
            "end",
            "manifest = Base.active_manifest()",
            "parsed = manifest isa AbstractString ? TOML.parsefile(manifest) : Dict{String, Any}()",
            "julia_version = get(parsed, \"julia_version\", nothing)",
            "if !(julia_version isa String)",
            "    error(\"Manifest julia_version is missing. See help setup.\")",
            "end",
            "parsed_version = try",
            "    VersionNumber(julia_version)",
            "catch",
            "    nothing",
            "end",
            "if !(parsed_version isa VersionNumber)",
            "    error(\"Manifest julia_version is not a Julia version. See help setup.\")",
            "end",
            "if Base.thisminor(parsed_version) != Base.thisminor(VERSION)",
            "    error(",
            "        \"Manifest julia_version \" * julia_version *",
            "        \" does not match this Julia \" * string(VERSION) *",
            "        \". See help setup.\",",
            "    )",
            "end",
            "Pkg.instantiate(; manifest=true, update_registry=false, julia_version_strict=true)",
        ),
        "\n",
    )
end

function instantiate_remotes(
        hosts::Vector{String},
        julia_path::String,
        remote_path::String,
        project::AbstractString;
        path_anchor::AbstractString = project,
    )::NamedTuple
    ensure_manifest_ships!(project)
    return _pkg_e_on_remotes(
        hosts, julia_path, remote_path, project;
        path_anchor = path_anchor,
        pkg_e = _instantiate_remote_e(),
        spin_label = "Instantiating",
    )
end

"""Run `Pkg.test()` of the **job** project on remote hosts (not DistSSHRun's tests)."""
function runtest_remotes(
        hosts::Vector{String},
        julia_path::String,
        remote_path::String,
        project::AbstractString;
        path_anchor::AbstractString = project,
    )::NamedTuple
    return _pkg_e_on_remotes(
        hosts, julia_path, remote_path, project;
        path_anchor = path_anchor,
        pkg_e = "using Pkg; Pkg.test()",
        spin_label = "Pkg.test",
    )
end

"""Resolve clone URL: `--repo` / `repo=` wins, else local `origin` (HTTPS GitHub → SSH)."""
function resolve_clone_url(
        repo_override::Union{Nothing, String},
        project::AbstractString;
        surface::Symbol = :cli,
    )
    if repo_override isa String
        repo = repo_override::String
        url = strip(repo)
        if !isempty(url)
            return normalize_git_clone_url(url)
        end
    end
    url = clone_url_from_local_origin(project)
    url === nothing && error(explain_clone_origin_missing(; surface = surface))
    return url
end
