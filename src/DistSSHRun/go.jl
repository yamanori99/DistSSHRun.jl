# `go` — as-is complete job entry (setup assumed done; sync → exec → collect).

"""One execution slot for [`go!`](@ref) (parent or child)."""
struct GoSlot
    kind::Symbol # :parent | :child
    host::Union{Nothing, String}
    label::String
end

"""Outcome of [`go!`](@ref). On failure, `failed_step` is `"sync"`, `"run"`, or `"collect"`.

`run_dir` is this run's `DISTSSH_RUN_DIR` when one is active.
Read it with [`result_run_dir`](@ref). [`result_provenance`](@ref) reads
`run.toml` from it. [`result_content_tree_hash`](@ref) and
[`result_ship_id`](@ref) read `provenance.selection` in that file.
Omitted `run_dir` uses [`kit_run_dir`](@ref), which
is `nothing` outside a run.

Result fields and positional constructors are not API. Result structs are
not a stable serialization format. `serialize` and JLD2 of a result are
unsupported. The supported record is `kit.result`.
"""
struct GoResult
    ok::Bool
    sync::Union{Nothing, SyncResult}
    run::Union{Nothing, DriveResult}
    collect::Union{Nothing, CollectResult}
    script::String
    output_dir::String
    failed_step::Union{Nothing, String}
    run_dir::Union{Nothing, String}
    function GoResult(
            ok::Bool,
            sync::Union{Nothing, SyncResult},
            run::Union{Nothing, DriveResult},
            collect::Union{Nothing, CollectResult},
            script::String,
            output_dir::String,
            failed_step::Union{Nothing, String},
            run_dir::Union{Nothing, String},
        )
        return new(ok, sync, run, collect, script, output_dir, failed_step, run_dir)
    end
end

function GoResult(
        ok::Bool,
        sync::Union{Nothing, SyncResult},
        run::Union{Nothing, DriveResult},
        collect::Union{Nothing, CollectResult},
        script::String,
        output_dir::String;
        failed_step::Union{Nothing, String} = nothing,
        run_dir::Union{Nothing, AbstractString} = nothing,
    )
    rd = run_dir === nothing ? kit_run_dir() : String(run_dir)
    return GoResult(ok, sync, run, collect, script, output_dir, failed_step, rd)
end

# Positional `failed_step`, the shape from before `run_dir`. The run
# directory still comes from the active `DISTSSH_RUN_DIR`.
function GoResult(
        ok::Bool,
        sync::Union{Nothing, SyncResult},
        run::Union{Nothing, DriveResult},
        collect::Union{Nothing, CollectResult},
        script::String,
        output_dir::String,
        failed_step::Union{Nothing, String},
    )
    return GoResult(ok, sync, run, collect, script, output_dir; failed_step = failed_step)
end

function kit_run_result(
        result::GoResult,
        tokens::AbstractVector{<:AbstractString} = String[],
    )::DistSSHJobResult
    return DistSSHJobResult(
        result.ok,
        :go,
        _optional_path(result.output_dir),
        nothing,
        result.failed_step,
        _result_exit_code(result.ok, result.run, result.collect, result.failed_step),
        HostRunResult[],
        tokens;
        run_dir = result.run_dir,
    )
end

const _GO_IO_LOCK = ReentrantLock()

_go_is_parent_host(host_name::AbstractString)::Bool = is_parent_host_name(host_name)

"""Sanitize a host name for use as a directory component."""
function _go_sanitize_label(raw::AbstractString)::String
    s = replace(String(raw), r"[^A-Za-z0-9._@+-]+" => "_")
    return isempty(s) ? "host" : s
end

"""True when a go token looks like a misspelling of `parent`."""
function _go_local_host_typo_hint(host_name::AbstractString)::Union{Nothing, String}
    h = lowercase(String(host_name))
    h in (
        "lacal", "loacl", "locahost", "locl",
        "parenthos", "parnthost", "parent",
        "masterhost", "masterhos", "materhost",
    ) &&
        return "did you mean parent?"
    return nothing
end

"""
Build execution slots from host tokens.

- Default: no slots unless `--head-slots N` and/or `N*host` tokens
- `--head-slots N` → N local subprocess slots (directory labels `<hostname>`, `<hostname>-2`, …)
- `N*host` → N SSH slots per token (`NAME-1` … when N>1 on one host)
- bare host without `N*` → error (except `--repeat`: uncapped)
- `total=N` (`--repeat N`): N independent runs, round-robin across listed
  hosts. `--head-slots` / `N*host` set per-host caps when listed.
"""
function _go_merge_repeat_cap(
        a::Union{Nothing, Int},
        b::Union{Nothing, Int},
    )::Union{Nothing, Int}
    a === nothing && return nothing
    b === nothing && return nothing
    return a + b
end

"""Host pool for `--repeat`: first-seen order; omit `:N` → unlimited cap."""
struct GoRepeatHost
    role::Symbol
    name::String
    cap::Union{Nothing, Int}
end

function _go_local_slot_count(
        host_tokens::AbstractVector{<:AbstractString},
        head_slots::Union{Nothing, Integer},
    )::Int
    ls, _ = resolve_go_head_slots(host_tokens, head_slots)
    return ls
end

"""Sanitized hostname for local go slot directory names."""
function _go_local_slot_label_base()::String
    return _go_sanitize_label(kit_head_host_label())
end

function _go_parent_slot_labels(parent_count::Int)::Vector{String}
    parent_count == 0 && return String[]
    base = _go_local_slot_label_base()
    parent_count == 1 && return [base]
    return ["$base-$i" for i in 1:parent_count]
end

"""Source name for a go slot label collision error."""
function _go_slot_label_source(slot::GoSlot)::String
    slot.kind === :parent && return "local ($(slot.label))"
    h = slot.host
    return h isa String ? h : slot.label
end

function _go_assert_unique_slot_labels!(slots::Vector{GoSlot})
    by_label = Dict{String, Vector{GoSlot}}()
    for s in slots
        push!(get!(by_label, s.label, GoSlot[]), s)
    end
    for (label, group) in by_label
        length(group) <= 1 && continue
        sources = unique(_go_slot_label_source(s) for s in group)
        throw(
            ArgumentError(
                "go slot directory label $(repr(label)) collides after sanitization " *
                    "(from $(join(sources, ", "))); rename one host token so the sanitized names differ",
            ),
        )
    end
    return nothing
end

function _go_append_child_slots!(slots::Vector{GoSlot}, remote_runs::Vector{String})
    counts = Dict{String, Int}()
    totals = Dict{String, Int}()
    for h in remote_runs
        totals[h] = get(totals, h, 0) + 1
    end
    for h in remote_runs
        counts[h] = get(counts, h, 0) + 1
        i = counts[h]
        nlab = totals[h]
        base = _go_sanitize_label(h)
        label = nlab == 1 ? base : "$base-$i"
        push!(slots, GoSlot(:child, h, label))
    end
    return nothing
end

function _go_repeat_pool(
        host_tokens::AbstractVector{<:AbstractString};
        head_slots::Union{Nothing, Integer} = nothing,
    )::Vector{GoRepeatHost}
    order = Tuple{Symbol, String}[]
    caps = Dict{Tuple{Symbol, String}, Union{Nothing, Int}}()
    local_name = _go_local_slot_label_base()
    parent_key = (:parent, local_name)
    if isempty(host_tokens)
        cap, _ = resolve_go_head_slots(host_tokens, head_slots)
        cap == 0 && return GoRepeatHost[]
        return [GoRepeatHost(:parent, local_name, cap)]
    end
    if head_slots !== nothing
        lw = Int(head_slots)
        lw < 0 && throw(ArgumentError("--head-slots must be >= 0, got $lw"))
        if lw > 0
            caps[parent_key] = lw
            push!(order, parent_key)
        end
    end
    for raw in host_tokens
        p = parse_placement_token(String(raw))
        p.role === :parent &&
            throw(ArgumentError("$(repr(raw)): use --head-slots for local runs, not tokens"))
        key = (p.role, p.name)
        cap = findfirst('*', String(raw)) === nothing ? nothing : p.n
        something(cap, 1) < 1 &&
            throw(ArgumentError("slot count must be >= 1, got $(something(cap, 1)) in $(repr(raw))"))
        if !haskey(caps, key)
            push!(order, key)
            caps[key] = cap
        else
            caps[key] = _go_merge_repeat_cap(caps[key], cap)
        end
    end
    pool = GoRepeatHost[]
    for key in order
        cap = caps[key]
        cap === 0 && continue
        push!(pool, GoRepeatHost(key[1], key[2], cap))
    end
    return pool
end

function _go_slots_from_repeat(
        pool::Vector{GoRepeatHost},
        assigned::AbstractVector{<:Integer},
    )::Vector{GoSlot}
    slots = GoSlot[]
    for (h, k) in zip(pool, assigned)
        k == 0 && continue
        if h.role === :parent
            labels = _go_parent_slot_labels(k)
            for label in labels
                push!(slots, GoSlot(:parent, nothing, label))
            end
        else
            remote_runs = fill(h.name, k)
            _go_append_child_slots!(slots, remote_runs)
        end
    end
    return slots
end

function _go_plan_slots(
        host_tokens::AbstractVector{<:AbstractString};
        total::Union{Nothing, Integer} = nothing,
        head_slots::Union{Nothing, Integer} = nothing,
    )::Vector{GoSlot}
    if total !== nothing
        n = Int(total)
        (total isa Bool || n < 1) && throw(ArgumentError("go repeat must be >= 1, got $total"))
        pool = _go_repeat_pool(host_tokens; head_slots = head_slots)
        isempty(pool) && throw(ArgumentError(zero_placement_usage_error(:go; surface = :api)))
        assigned = zeros(Int, length(pool))
        start = 1
        nh = length(pool)
        for _ in 1:n
            placed = false
            for off in 0:(nh - 1)
                j = mod1(start + off, nh)
                cap = pool[j].cap
                if cap === nothing || assigned[j] < cap
                    assigned[j] += 1
                    start = mod1(j + 1, nh)
                    placed = true
                    break
                end
            end
            placed || throw(
                ArgumentError(
                    "repeat $n exceeds per-host caps (`--head-slots` / `N*host`)",
                )
            )
        end
        slots = _go_slots_from_repeat(pool, assigned)
        _go_assert_unique_slot_labels!(slots)
        return slots
    end
    parent_count = _go_local_slot_count(host_tokens, head_slots)
    parent_label_base = _go_local_slot_label_base()
    remote_runs = Vector{String}()
    for raw in host_tokens
        p = parse_placement_token(String(raw))
        n = something(p.n, 1)
        if n < 1
            throw(ArgumentError("slot count must be >= 1, got $n in $(repr(raw))"))
        end
        for _ in 1:n
            push!(remote_runs, p.name)
        end
    end
    parent_count == 0 && isempty(remote_runs) &&
        throw(ArgumentError(zero_placement_usage_error(:go; surface = :api)))
    slots = GoSlot[]
    if parent_count == 1 && isempty(remote_runs)
        push!(slots, GoSlot(:parent, nothing, parent_label_base))
    else
        for label in _go_parent_slot_labels(parent_count)
            push!(slots, GoSlot(:parent, nothing, label))
        end
    end
    _go_append_child_slots!(slots, remote_runs)
    _go_assert_unique_slot_labels!(slots)
    return slots
end

function placement_tokens_from_go_slots(slots::Vector{GoSlot})::Vector{String}
    order = String[]
    counts = Dict{String, Int}()
    for s in slots
        s.kind === :child || continue
        h = s.host
        h isa String || continue
        if !haskey(counts, h)
            push!(order, h)
            counts[h] = 0
        end
        counts[h] += 1
    end
    out = String[]
    for h in order
        push!(out, format_placement_token(:child, h, counts[h]))
    end
    return out
end

# Resolve symlinks first so an in-tree link to outside counts as outside; else `_path_under_resolved`.
function _script_inside_project(project::AbstractString, script::AbstractString)::Bool
    p = canonical_local_path(script)
    r = canonical_local_path(project)
    if ispath(p) && ispath(r)
        try
            ps = canonical_local_path(realpath(p))
            pr = canonical_local_path(realpath(r))
            return _path_is_under(ps, pr)
        catch
        end
    end
    return _path_under_resolved(p, r)
end

function _go_script_relpath(project::AbstractString, script::AbstractString)::String
    path = canonical_local_path(script)
    if !_script_inside_project(project, script)
        return joinpath(EXTERNAL_DIR_NAME, basename(path))
    end
    proj = canonical_local_path(project)
    try
        ispath(proj) && (proj = canonical_local_path(realpath(proj)))
        ispath(path) && (path = canonical_local_path(realpath(path)))
    catch
    end
    rel = relpath(path, proj)
    return rel == "." ? basename(path) : rel
end

"""
    remote_script_path(work_root, project, script) -> String

Remote path of `script` after a ship. `work_root` is the remote project
directory (`ships/<id>/src` plus the project directory inside the tar).

A script inside `project` keeps its relative path under `work_root`. A script
outside it is `work_root/_distsshrun_external/<basename>`, the same place
`extra_files` uses. One external file is the limit; a second is an error at
[`ship_tree!`](@ref).
"""
function remote_script_path(
        work_root::AbstractString,
        project::AbstractString,
        script::AbstractString,
    )::String
    rel = replace(_go_script_relpath(project, script), '\\' => '/')
    root = rstrip(replace(String(work_root), '\\' => '/'), '/')
    return rel == "." ? root : string(root, "/", rel)
end
public remote_script_path

"""Absolute path that is not a local file: the child was given the remote script."""
function _remote_script_argv(script::AbstractString)::Bool
    return isabspath(String(script)) && !isfile(String(script))
end

"""`{script}/.distssh/go` when the script is in `project`, else `{project}/.distssh/go`."""
function _go_kit_parent(
        project::AbstractString,
        script::AbstractString,
    )::String
    proj = canonical_local_path(project)
    script_path = canonical_local_path(script)
    if _script_inside_project(project, script)
        return kit_dir_beside_script(dirname(script_path), :go)
    end
    return kit_dir_beside_script(proj, :go)
end

"""Batch output directory: `{.distssh/go}/<stem>_<UTC>/` (`kit.progress` + slots).

Creates the leaf with exclusive `mkdir`. Same-second collisions get a
nanosecond suffix (`_mkdir_unique!`).
"""
function _go_batch_output_dir(
        project::AbstractString,
        script::AbstractString;
        now::DateTime = Dates.now(Dates.UTC),
    )::String
    stem = splitext(basename(canonical_local_path(script)))[1]
    stamp = Dates.format(now, dateformat"yyyymmddTHHMMSS") * "Z"
    dir = joinpath(_go_kit_parent(project, script), "$(stem)_$(stamp)")
    return _mkdir_unique!(dir)
end

function _go_julia_exe()::String
    return resolve_controller_julia("auto")
end

"""Resolve Julia binary for `go!` (`nothing` / `"auto"` / empty → detect or local exe).

Remote auto-detect failures throw (no bare `"julia"` PATH fallback).
"""
function _go_resolve_julia(
        ::Nothing = nothing;
        host::Union{Nothing, AbstractString} = nothing,
    )::String
    host isa AbstractString || return _go_julia_exe()
    found = resolve_remote_julia(String(host), "auto")
    found === nothing && throw(
        ArgumentError(
            "Julia not found on remote host $(host) (auto-detect failed)",
        )
    )
    return found
end

function _go_resolve_julia(
        julia::AbstractString;
        host::Union{Nothing, AbstractString} = nothing,
    )::String
    s = strip(String(julia))
    (isempty(s) || lowercase(s) == "auto") && return _go_resolve_julia(nothing; host = host)
    if host isa AbstractString
        found = resolve_remote_julia(String(host), s)
        found === nothing && throw(
            ArgumentError(
                "Julia not usable on remote host $(host) at $(s)",
            )
        )
        return found
    end
    return resolve_controller_julia(s)
end

function _go_write_batch_manifest!(
        batch_dir::AbstractString,
        script::AbstractString,
        slots::Vector{GoSlot},
    )
    path = joinpath(batch_dir, "go_manifest.txt")
    open(path, "w") do io
        println(io, "script=", script)
        println(io, "slots=", length(slots))
        for (i, s) in enumerate(slots)
            host = s.host === nothing ? PARENT_HOST_NAME : s.host
            println(io, "slot[$i]=", s.label, " kind=", s.kind, " host=", host)
        end
    end
    return path
end

function _go_echo_script_log!(log_path::AbstractString)
    isfile(log_path) || return
    for line in eachline(log_path)
        writeln_both("  " * line)
    end
    return nothing
end

"""Replay each slot's `julia.stdout.log` after the live bar (`:progress` only)."""
function _print_go_slot_stdout_after_progress!(batch_dir::AbstractString)
    kit_output_progress() || return nothing
    logs = String[]
    isdir(batch_dir) || return nothing
    for (root, _, files) in walkdir(batch_dir)
        "julia.stdout.log" in files && push!(logs, joinpath(root, "julia.stdout.log"))
    end
    sort!(logs)
    isempty(logs) && return nothing
    many = length(logs) > 1
    for path in logs
        body = read(path, String)
        isempty(strip(body)) && continue
        if many
            println(stdout, relpath(dirname(path), batch_dir), ":")
        end
        print(stdout, body)
        endswith(body, '\n') || println(stdout)
    end
    return nothing
end

"""
Last `path:line` from Julia `--trace-eval` / `Base.TRACE_EVAL` text.

Strips ANSI color. Skips the `-L` job mark (`distsshkit-job:`). `nothing`
when no top-level location was recorded. `full` lines carry the location
inside `#= path:line =#`.
"""
function _last_trace_location(text::AbstractString)::Union{Nothing, String}
    cleaned = replace(String(text), r"\e\[[0-9;]*m" => "")
    last = nothing
    for line in eachsplit(cleaned, '\n'; keepempty = false)
        occursin("eval:", line) || continue
        occursin("distsshkit-job:", line) && continue
        for m in eachmatch(r"#= (.+):([0-9]+) =#", line)
            path = String(something(m.captures[1], ""))
            occursin("distsshkit-job:", path) && continue
            last = string(path, ":", something(m.captures[2], ""))
        end
    end
    return last
end

"""` last top-level: path:line` from a slot log, or `""`."""
function _go_trace_suffix(slot_dir::Union{Nothing, AbstractString})::String
    slot_dir === nothing && return ""
    log_path = joinpath(String(slot_dir), "julia.stdout.log")
    isfile(log_path) || return ""
    loc = try
        _last_trace_location(read(log_path, String))
    catch
        nothing
    end
    loc === nothing && return ""
    return " last top-level: " * loc
end

function _go_run_local_slot!(
        project::AbstractString,
        script::AbstractString,
        script_args::AbstractVector{<:AbstractString},
        slot_dir::AbstractString;
        quiet::Bool = false,
        julia::Union{Nothing, AbstractString} = nothing,
    )::DriveResult
    mkpath(slot_dir)
    log_path = joinpath(slot_dir, "julia.stdout.log")
    julia_bin = pin_local_julia(julia)
    extra_L = String[]
    job_id = resolved_kit_job_id()
    if job_id !== nothing
        push!(extra_L, kit_write_job_mark_file(slot_dir, job_id))
    end
    loader = write_go_slot_loader(slot_dir)
    loader !== nothing && push!(extra_L, loader)
    hs_loader = write_go_handshake_loader(slot_dir)
    hs_loader !== nothing && push!(extra_L, hs_loader)
    argv = go_slot_julia_argv(
        julia_bin, project, script, script_args;
        local_cpu = true, extra_L = extra_L,
    )
    env_pairs = worker_env_pairs(
        project;
        extra = ["DISTSSH_OUTPUT_DIR" => String(slot_dir)],
        rank = take_worker_rank(),
    )
    notice = launch_override_notice(PARENT_HOST_NAME, launch_override_names(ENV))
    (quiet || isempty(notice)) || writeln_both(notice)
    cmd = addenv(ignorestatus(Cmd(argv)), env_pairs...)
    site = "GoParent slot=$(basename(slot_dir))"
    proc = run_go_slot_with_handshake(cmd, site, log_path)
    # Mirror script stdout in `:verbose` only (quiet/progress own the TTY).
    if !quiet && kit_output_detail() && isfile(log_path)
        lock(_GO_IO_LOCK) do
            _go_echo_script_log!(log_path)
            writeln_both("")
        end
    end
    code = DistSSHBase.shell_status(proc)
    return DriveResult(code == 0, code; output_dir = slot_dir)
end

"""Remote path of a go slot: relative to `proj` when `slot_dir` is inside `proj`, else under `.distssh/go/`."""
function _go_remote_slot_rel(
        proj::AbstractString,
        slot_dir::AbstractString,
        batch_dir::AbstractString,
        slot_label::AbstractString,
    )::String
    proj_abs = canonical_local_path(proj)
    slot_abs = canonical_local_path(slot_dir)
    if _path_under_resolved(slot_abs, proj_abs) && slot_abs != proj_abs
        rel = String(relpath(slot_abs, proj_abs))
        if rel != "." && !startswith(rel, "..")
            return rel
        end
    end
    batch = basename(canonical_local_path(batch_dir))
    label = String(slot_label)
    (isempty(batch) || batch == "." || batch == "..") && (batch = "batch")
    (isempty(label) || label == "." || label == "..") && (label = "slot")
    return joinpath(DistSSHBase.LOCAL_STATE_DIR, "go", batch, label)
end

"""Remote SSH shell snippet for one `go` slot (cd project root before mkdir/log paths)."""
function _go_remote_slot_shell_inner(
        remote_root::AbstractString,
        slot_rel::AbstractString,
        script_rel::AbstractString,
        script_args::AbstractVector{<:AbstractString},
        julia_bin::AbstractString,
    )::String
    rr = _remote_shell_path_word(remote_root)
    rel_q = _remote_shell_path_word(script_rel)
    slot_q = _remote_shell_path_word(slot_rel)
    # `join(xs, delim)` infers `Union{String,Nothing}` (IO method) on 1.13.
    args_s = sprint() do io
        for a in script_args
            print(io, ' ', _remote_shell_path_word(a))
        end
    end
    isempty(_PLANNED_RANK_QUEUE) && reset_launch_rank_plan!([1])
    rank = take_worker_rank()
    seed = job_seed()
    wseed = worker_seed(seed, rank)
    seed_export = "export DISTSSH_JOB_SEED=$(seed) DISTSSH_WORKER_RANK=$(rank) DISTSSH_WORKER_SEED=$(wseed) && "
    jb_launch = go_remote_julia_prefix(julia_bin; blas = _explicit_blas_threads())
    log_q = _remote_shell_path_word(joinpath(slot_rel, "julia.stdout.log"))
    exit_q = _remote_shell_path_word(joinpath(slot_rel, "go.exitcode"))
    job_id = resolved_kit_job_id()
    job_export = ""
    job_load = ""
    job_mark = ""
    if job_id !== nothing
        mark_rel = joinpath(slot_rel, kit_job_pkill_pattern(job_id))
        mark_q = _remote_shell_path_word(mark_rel)
        # The mark file is a shell comment. Quote it even though the path word
        # is already quoted: the printf argument is the comment text.
        comment_q = "'" * kit_job_mark_comment(job_id) * "'"
        job_export = "export DISTSSH_JOB_ID=$(_remote_shell_path_word(job_id)) && "
        job_mark = "printf '%s\\n' $comment_q > $mark_q && "
        job_load = " -L $mark_q"
    end
    kit_q = _remote_shell_path_word(joinpath(slot_rel, DistSSHBase.LOCAL_STATE_DIR))
    loader_q = _remote_shell_path_word(joinpath(slot_rel, DistSSHBase.LOCAL_STATE_DIR, _GO_SLOT_LOADER_NAME))
    hs_q = _remote_shell_path_word(joinpath(slot_rel, DistSSHBase.LOCAL_STATE_DIR, _GO_HANDSHAKE_LOADER_NAME))
    # Quoted heredoc: the slot has no DistSSHRun, so the snapshot source travels in the command.
    write_loader = "cat > $loader_q << 'DISTSSH_INTERNAL_PROVENANCE_SLOT'\n$(_GO_SLOT_LOADER_SRC)\nDISTSSH_INTERNAL_PROVENANCE_SLOT\n"
    write_hs = "cat > $hs_q << 'DISTSSH_INTERNAL_GO_HS'\n$(_GO_HANDSHAKE_LOADER_SRC)\nDISTSSH_INTERNAL_GO_HS\n"
    prov_load = " -L $loader_q -L $hs_q"
    job_for_lock = job_id === nothing ? "" : job_id
    hold_lock = output_lock_hold_shell(slot_q, job_for_lock)
    return string(
        _output_lock_hold_shell_helpers(),
        "cd $rr && mkdir -p $slot_q && mkdir -p $kit_q && ",
        hold_lock,
        " || exit 1 && ",
        "export DISTSSH_OUTPUT_DIR=$slot_q && ",
        seed_export,
        job_export,
        job_mark,
        write_loader,
        write_hs,
        "{ $jb_launch$job_load$prov_load $rel_q$args_s 2>&1; echo \$? > $exit_q; } | tee $log_q; ",
        "ec=\$(sed -n '1p' $exit_q 2>/dev/null); ",
        "case \"\$ec\" in ''|*[!0-9]*) ec=127;; esac; exit \$ec",
    )
end

function _go_run_remote_slot!(
        host::AbstractString,
        project::AbstractString,
        remote_root::AbstractString,
        script::AbstractString,
        script_args::AbstractVector{<:AbstractString},
        slot_rel::AbstractString,
        slot_dir::AbstractString;
        quiet::Bool = false,
        julia::Union{Nothing, AbstractString} = nothing,
    )::DriveResult
    mkpath(slot_dir)
    rel = _go_script_relpath(project, script)
    julia_bin = something(pin_remote_julia(String(host), julia), _go_resolve_julia(julia; host = String(host)))
    inner = _go_remote_slot_shell_inner(
        remote_root, slot_rel, rel, script_args, julia_bin,
    )
    cmd = ignorestatus(_host_sync_remote_shell_cmd(String(host), inner; forward_stdin = true))
    site = "GoRemoteSlot host=$(String(host)) slot=$(basename(slot_dir))"
    log_path = joinpath(slot_dir, "julia.stdout.log")
    proc = run_go_slot_with_handshake(cmd, site, log_path)
    out = isfile(log_path) ? read(log_path, String) : ""
    # Collect is skipped when the slot fails, so keep the captured log locally.
    log_path = joinpath(slot_dir, "julia.stdout.log")
    if !isempty(out) && !isfile(log_path)
        write(log_path, out)
    end
    # `:verbose` only: quiet/progress suppress script echo (still in slot logs).
    if !quiet && kit_output_detail() && !isempty(out)
        lock(_GO_IO_LOCK) do
            write(stdout, out)
        end
    end
    # A dead ssh with no exit file must not become success (`exitcode` is 0).
    ssh_code = DistSSHBase.shell_status(proc)
    # Prefer the remote-written exit file when ssh status is unreliable.
    ec_path = joinpath(slot_dir, "go.exitcode")
    scp_failed = false
    try
        remote_ec = string(rstrip(remote_root, '/'), "/", slot_rel, "/go.exitcode")
        DistSSHBase._ensure_posix_login_shell!(String(host))
        _, remote_spec = DistSSHBase._scp_remote_file_spec(host, remote_ec)
        run_ssh(
            pipeline(
                _scp_cmd(vcat(DistSSHBase.scp_connection_argv(host), [remote_spec, ec_path]));
                stdout = devnull,
                stderr = devnull,
            );
            wait = true,
        )
    catch e
        _rethrow_missing_host_tool(e)
        scp_failed = true
    end
    code = _go_slot_exitcode(ssh_code, ec_path; scp_failed)
    return DriveResult(code == 0, code; output_dir = slot_dir)
end

"""Prefer `go.exitcode` when present. If scp failed, ignore a local file (may be stale)."""
function _go_slot_exitcode(
        ssh_code::Int,
        ec_path::AbstractString;
        scp_failed::Bool,
    )::Int
    if !scp_failed && isfile(ec_path)
        parsed = tryparse(Int, strip(read(ec_path, String)))
        parsed !== nothing && return parsed
    end
    return scp_failed ? 1 : ssh_code
end

"""Tar one remote slot directory into the local slot directory (slot-overwrite collect)."""
function _go_pull_slot!(
        host::AbstractString,
        remote_root::AbstractString,
        slot_rel::AbstractString,
        slot_dir::AbstractString;
        julia::Union{Nothing, AbstractString} = nothing,
    )::Bool
    mkpath(slot_dir)
    remote_slot = joinpath(remote_root, slot_rel)
    try
        _pull_tar_tree!(
            host, remote_slot, slot_dir;
            julia_bin = _pull_remote_julia(host, julia),
            drop_rels = String[".distssh.lock"],
        )
        return true
    catch e
        _rethrow_missing_host_tool(e)
        return false
    end
end

"""Copy one remote slot snapshot when collect did not bring the slot directory back."""
function _go_fetch_slot_provenance!(
        host::AbstractString,
        remote_root::AbstractString,
        slot_rel::AbstractString,
        slot_dir::AbstractString,
    )
    remote_snap = string(
        rstrip(remote_root, '/'), "/", slot_rel, "/", DistSSHBase.LOCAL_STATE_DIR, "/", _GO_SLOT_PROVENANCE_NAME,
    )
    local_dir = joinpath(slot_dir, DistSSHBase.LOCAL_STATE_DIR)
    mkpath(local_dir)
    local_snap = joinpath(local_dir, _GO_SLOT_PROVENANCE_NAME)
    try
        DistSSHBase._ensure_posix_login_shell!(String(host))
        _, remote_spec = DistSSHBase._scp_remote_file_spec(host, remote_snap)
        run_ssh(
            pipeline(
                _scp_cmd(vcat(DistSSHBase.scp_connection_argv(host), [remote_spec, local_snap]));
                stdout = devnull,
                stderr = devnull,
            );
            wait = true,
        )
    catch e
        _rethrow_missing_host_tool(e)
    end
    return nothing
end

"""Run one slot (local process or remote SSH). Isolated env per slot. Pull is `_go_collect_slot!`."""
function _go_exec_slot!(
        slot::GoSlot,
        proj::AbstractString,
        script_path::AbstractString,
        args::AbstractVector{<:AbstractString},
        batch_dir::AbstractString,
        remote_root::AbstractString;
        quiet::Bool = false,
        julia::Union{Nothing, AbstractString} = nothing,
    )
    slot_dir = joinpath(batch_dir, slot.label)
    mkpath(slot_dir)
    run_lab = string(slot.label, "/run")
    _kit_progress_span!(run_lab, :running)
    if slot.kind === :parent
        run_res = _go_run_local_slot!(
            proj, script_path, args, slot_dir; quiet = quiet, julia = julia,
        )
    else
        host = slot.host::String
        slot_rel = _go_remote_slot_rel(proj, slot_dir, batch_dir, slot.label)
        run_res = _go_run_remote_slot!(
            host,
            proj,
            remote_root,
            script_path,
            args,
            slot_rel,
            slot_dir;
            quiet = quiet,
            julia = julia,
        )
    end
    _kit_progress_span!(run_lab, run_res.ok ? :ok : :fail)
    token = slot.kind === :parent ? PARENT_HOST_NAME : String(something(slot.host, slot.label))
    note_go_slot_provenance!(token, slot_dir)
    return (run = run_res, collect = nothing, collect_fail = false)
end

"""Rsync one successful remote slot after every script has finished."""
function _go_collect_slot!(
        slot::GoSlot,
        proj::AbstractString,
        batch_dir::AbstractString,
        remote_root::AbstractString;
        julia::Union{Nothing, AbstractString} = nothing,
    )
    slot.kind === :child || return (collect = nothing, collect_fail = false)
    host = slot.host::String
    slot_dir = joinpath(batch_dir, slot.label)
    slot_rel = _go_remote_slot_rel(proj, slot_dir, batch_dir, slot.label)
    col_lab = string(slot.label, "/collect")
    _kit_progress_span!(col_lab, :running)
    if _go_pull_slot!(host, remote_root, slot_rel, slot_dir; julia = julia)
        _kit_progress_span!(col_lab, :ok)
        return (collect = CollectResult(true, 0), collect_fail = false)
    end
    _kit_progress_span!(col_lab, :fail)
    return (collect = CollectResult(false, 1), collect_fail = true)
end

"""Log header matching drive: subcommand args, Julia env, then the go banner."""
function _go_print_run_header!(
        original_args::Vector{String},
        script_path::AbstractString,
        script_args::AbstractVector{<:AbstractString},
        slots::Vector{GoSlot},
        proj::AbstractString,
        anchor::AbstractString;
        implicit_no_hosts::Bool = false,
    )
    writeln_field("Subcommand args", subcommand_args_record("go", original_args))
    for (label, value) in julia_env_record()
        writeln_field(label, value)
    end
    writeln_both("")
    print_header(cli_heading("go"))
    writeln_both("")
    writeln_field("Script", display_path(script_path, anchor))
    writeln_field("Args", isempty(script_args) ? "—" : join(script_args, " "))
    writeln_field("Project", cli_project_disp(proj, anchor))
    writeln_field("DistSSHRun", dist_ssh_kit_version())
    app_git = get_local_git_hash(proj; short = 8)
    writeln_field("App git", app_git === nothing ? "unavailable" : app_git)
    writeln_field("Slots", string(length(slots)))
    for s in slots
        where = if s.kind === :parent
            implicit_no_hosts ? format_kit_go_implicit_head_slot() :
                format_kit_head_placement(1, "slots")
        else
            String(something(s.host, s.label))
        end
        writeln_both("  · $(s.label)  ($where)"; color = :light_black)
    end
    writeln_both("")
    return nothing
end

function _go_complete!(
        result::GoResult,
        batch_dir::AbstractString,
        release_lock,
        progress_ok::Bool,
        proj::AbstractString,
        anchor,
        tokens::Vector{String},
    )::GoResult
    footer = progress_ok ? display_path(batch_dir, anchor) : nothing
    kit_progress_done!(; ok = progress_ok, footer = footer)
    _print_go_slot_stdout_after_progress!(batch_dir)
    _maybe_print_kit_progress_phases(batch_dir)
    close_log_file()
    _set_kit_progress_sidecar!(nothing)
    kr = kit_run_result(result, tokens)
    _write_kit_result_file(kr)
    rd = kit_run_dir()
    try
        if rd !== nothing
            try
                note_controller_shipped_tree_drift!(proj)
            catch err
                kit_println(
                    "shipped-tree drift check skipped: $(sprint(showerror, err; context = 0))",
                )
            end
            write_kit_run_toml!(
                rd;
                kind = :go,
                output_dir = batch_dir,
                log_dir = batch_dir,
                result = kr,
                project_root = String(anchor),
                provenance = assemble_provenance(),
            )
        end
    finally
        release_lock()
        _remove_kit_pid_file(getpid(), batch_dir, nothing)
    end
    return result
end

"""
    go!(script, workers...; kwargs...)
    go!(script, workers::AbstractVector; kwargs...)

Run an as-is complete job on one or more slots (local and/or remote).

`[provenance]` records this controller under `julia.parent` and `machine.parent`.
Each slot that ran the script is under `workers`, grouped by placement token.
The manifest hash and the git snapshot are taken when `go!` starts.

```julia
go!("job.jl")                          # one parent slot
go!("job.jl"; repeat=100)              # 100 independent runs on parent
go!("job.jl", "parent:2"; args=["8"])
go!("job.jl", "1*user@h1", "1*user@h2"; remote="/path/to/project")
```

Each slot gets `DISTSSH_OUTPUT_DIR` pointing at
`{script}/.distssh/go/<stem>_<UTC>/<slot>/`.
Override the batch root with `output_dir` (CLI: `--output-dir`). For backward
compatibility `collect_spec::AbstractString` also sets the batch root, but passing
both `output_dir` and `collect_spec::String` is an error. `collect_spec === false`
means "skip collect" and is orthogonal to `output_dir`.

Default `sync` is `false` (no pre-run sync; remotes are checked first — setup
is assumed done). The `go` CLI does not take `--ship-tree` or `--git-sync`;
prepare with `setup ship-tree` or `setup git-sync`, then `setup instantiate`
when needed, then `go --ship-id ID`. Passing `sync=:git_sync` or
`sync=:ship_tree` on [`go!`](@ref) is an `ArgumentError`. `ship_id`
(CLI `--ship-id`) selects `ships/<ID>/src` when `sync` is omitted or `false`.
A script outside the project is allowed with `ship_id` when that ship used
`extra_files=[script]`. The remote command is
[`remote_script_path`](@ref): `_distsshrun_external/<basename>` under the
selected project directory. `ship_id` also skips the in-tree
`[sources]` check: a sibling path dependency was already shipped.
`go!` has no git-parity gate; use [`drive!`](@ref) with
`skip_hash_check=false` (CLI: `drive --require-git`) when you need that.

`julia` sets the Julia binary for each slot (`nothing` / `"auto"` → detect;
same as CLI `--julia`).

`unsafe_skip_env_digests` (CLI `--unsafe-skip-env-digests`) waives only Manifest and
Project byte digest checks across slots (recorded as unverified). Julia build
and DistSSH* Manifest version strings must still match. Digest comparison is
byte-exact (CRLF differences count).

When `workers` is empty and `hosts_file` is omitted, `DISTSSH_HOSTS_FILE`
is still read (API `go!("job.jl")`). Non-empty `workers` (CLI
[`host_tokens`](@ref)) does not re-read that ENV.

`head_slots` (CLI `--head-slots N`) adds N local subprocess runs on this machine.
`N*host` tokens add SSH full-script runs. Together they start in one batch.
`repeat=N` (CLI `--repeat N`) is the total number of those runs, spread
round-robin across listed hosts and local slots.
Without `repeat`, every host token needs an explicit `N*` count and at least one
slot must be configured (`head_slots` and/or remotes).
`path_anchor` shortens displayed paths (CLI passes kit project root).
"""
function go!(
        script::AbstractString,
        workers::AbstractVector{<:AbstractString};
        project::AbstractString = pwd(),
        remote::Union{Nothing, AbstractString} = nothing,
        hosts_file::Union{Nothing, AbstractString} = nothing,
        hosts_file_tokens_merged::Bool = false,
        quiet::Bool = false,
        verbosity::Union{Nothing, Symbol} = nothing,
        yes::Union{Nothing, Bool} = nothing,
        output_dir::Union{Nothing, AbstractString} = nothing,
        collect_spec::Union{Bool, AbstractString, Nothing} = nothing,
        args::AbstractVector{<:AbstractString} = String[],
        path_anchor::Union{Nothing, AbstractString} = nothing,
        julia::Union{Nothing, AbstractString} = nothing,
        hint_surface::Symbol = :api,
        original_args::Vector{String} = String[],
        repeat::Union{Nothing, Integer} = nothing,
        unsafe_skip_env_digests = missing,
        unsafe_expose_port = missing,
        unsafe_all_to_all = missing,
        ship_id::Union{Nothing, AbstractString} = nothing,
        sync::Union{Symbol, Bool, Nothing} = nothing,
        allow_external_symlinks::Bool = false,
        allow_mismatch = nothing,
        head_slots::Union{Nothing, Integer} = nothing,
        env::Union{Nothing, ProcessEnv} = nothing,
    )::GoResult
    yes !== nothing && throw(
        ArgumentError(
            "go! does not accept yes=; confirmation is CLI-only (pass -y/--yes to julia -m DistSSHKit)",
        ),
    )
    _reject_removed_allow_mismatch!(allow_mismatch)
    _reject_run_transfer_kw!("go!", sync; surface = hint_surface)
    allow_external_symlinks &&
        _reject_run_transfer_cli!(hint_surface === :cli ? "go" : "go", "--allow-external-symlinks")
    remote_argv = _remote_script_argv(script)
    script_path = remote_argv ? String(script) : canonical_local_path(script)
    snap_arg = ship_id === nothing ? nothing : validate_ship_id(ship_id)
    proj = canonical_local_path(project)
    if !isfile(script_path) && !(remote_argv && snap_arg !== nothing)
        throw(
            ArgumentError(
                explain_script_not_found(
                    script_path,
                    proj;
                    surface = hint_surface,
                    headline = "script not found: $script_path",
                )
            )
        )
    end
    _acquire_kit_inproc_run!(:go)
    pe = env === nothing ? snapshot_process_env() : env
    old_run = get(ENV, DISTSSH_RUN_DIR_ENV, nothing)
    inherited_run = old_run isa AbstractString && !isempty(strip(old_run))
    return with_kit_invocation_env!(pe) do
        try
            _reset_run_provenance!(proj)
            _clear_active_selection!()
            _clear_active_deploy_record_unless_ship_id!(snap_arg)
            warn_project_sshflags(proj)
            _ensure_kit_run_dir!(:go, script_path; project = proj)
            cfg = resolve_run_job_config(;
                command = :go,
                cli_unsafe_skip_env_digests = cli_optional_bool(unsafe_skip_env_digests),
                cli_unsafe_expose_port = cli_optional_bool(unsafe_expose_port),
                cli_unsafe_all_to_all = cli_optional_bool(unsafe_all_to_all),
                env = pe,
            )
            return with_run_unsafe_options!(cfg) do
                return _go_run!(
                    script_path,
                    proj,
                    workers,
                    remote,
                    hosts_file,
                    hosts_file_tokens_merged,
                    quiet,
                    verbosity,
                    output_dir,
                    collect_spec,
                    args,
                    path_anchor,
                    julia,
                    hint_surface,
                    original_args,
                    repeat,
                    inherited_run,
                    snap_arg,
                    head_slots,
                )
            end
        finally
            _restore_kit_run_dir_env!(old_run)
            _release_kit_inproc_run!()
        end
    end
end

function _go_run!(
        script_path::String,
        proj::String,
        workers,
        remote,
        hosts_file,
        hosts_file_tokens_merged::Bool,
        quiet,
        verbosity,
        output_dir,
        collect_spec,
        args,
        path_anchor,
        julia,
        hint_surface,
        original_args,
        repeat,
        inherited_run::Bool,
        snap_arg::Union{Nothing, String} = nothing,
        head_slots::Union{Nothing, Integer} = nothing,
    )
    anchor = something(path_anchor, proj)

    tokens = String[String(h) for h in workers]
    hf = merge_go_hosts_file_worker_tokens!(
        tokens, hosts_file;
        hosts_file_tokens_merged = hosts_file_tokens_merged,
        surface = hint_surface,
        honor_distssh_hosts_file_env = head_slots === nothing,
    )
    if hf !== nothing && !isempty(strip(String(hf)))
        try
            resolve_launch_bind_overrides(;
                hosts_file = hf,
                surface = hint_surface,
                planned_hosts = String[split_worker_token(t)[1] for t in tokens],
                command = :go,
            )
        catch e
            e isa ArgumentError || rethrow()
            hint_surface === :cli &&
                throw(DistSSHBase.CliUsageError(_bind_config_cli_message(e.msg)))
            rethrow()
        end
    end
    if repeat === nothing
        require_counted_placement_tokens(
            tokens;
            command = :go,
            surface = hint_surface,
            head_slots = head_slots,
        )
    end
    slots = _go_plan_slots(tokens; total = repeat, head_slots = head_slots)
    reset_launch_rank_plan!(collect(1:length(slots)))
    place = placement_tokens_from_go_slots(slots)
    if output_dir !== nothing && collect_spec isa AbstractString
        throw(
            ArgumentError(
                "go!: set the batch root via output_dir OR collect_spec::String, not both",
            )
        )
    end
    if snap_arg !== nothing
        assert_controller_environment_for_shipped_run!(proj)
    else
        assert_controller_environment_for_verify!(proj)
    end
    batch_dir = if output_dir !== nothing
        _prepare_output_dir!(
            output_dir;
            command = :go,
            surface = hint_surface,
            allow_parent_sidecars = inherited_run,
        )
    elseif collect_spec isa AbstractString
        _prepare_output_dir!(
            collect_spec;
            command = :go,
            surface = hint_surface,
            allow_parent_sidecars = inherited_run,
        )
    else
        _go_batch_output_dir(proj, script_path)
    end
    mkpath(batch_dir)
    release_lock = output_dir_lock!(batch_dir; id = resolved_kit_job_id())
    _go_write_batch_manifest!(batch_dir, script_path, slots)
    _set_kit_progress_sidecar!(batch_dir)
    go_env_session = DistSSHSession(
        project = proj,
        workers = String[],
        remote = remote,
        quiet = quiet,
        verbosity = verbosity,
    )
    return _with_session_env!(go_env_session) do
        init_log_file(batch_dir; prefix = "go", path_anchor = anchor)

        progress_ok = false
        completed = false
        try
            go_session = DistSSHSession(
                project = proj,
                workers = String[],
                remote = remote,
                quiet = quiet,
                verbosity = verbosity,
            )
            sess_rr = session_remote_root(go_session)

            child_hosts = unique(String[s.host for s in slots if s.kind === :child])
            remote_argv = _remote_script_argv(script_path)
            _reject_script_outside_project_run!(
                "go!",
                proj,
                script_path;
                ship_id = snap_arg,
                remote_argv = remote_argv,
            )
            _write_kit_hosts_file(child_hosts, batch_dir, nothing)

            skip_collect = collect_spec === false
            any_run_fail = Ref(false)
            any_collect_fail = Ref(false)
            last_run = Ref(DriveResult(true, 0))
            first_fail_run = Ref{Union{Nothing, DriveResult}}(nothing)
            last_collect = Ref{Union{Nothing, CollectResult}}(nothing)

            _, implicit_no_hosts = resolve_go_head_slots(tokens, head_slots)
            _go_print_run_header!(
                original_args, script_path, args, slots, proj, anchor;
                implicit_no_hosts = implicit_no_hosts,
            )

            n_slots = length(slots)
            if n_slots > 0
                kit_progress_begin!(
                    "go";
                    steps = n_slots,
                    items = String[s.label for s in slots],
                    kind = :go,
                )
                _kit_progress_mark!("ready")
            end
            sync_result = nothing
            run_rr = if isempty(child_hosts)
                sess_rr
            else
                rr = _project_work_root(
                    child_hosts, proj; cli_override = remote, ship_id = snap_arg,
                )
                doctor_launch_assert_hosts!(child_hosts, rr; local_project = proj)
                rr
            end

            if !isempty(child_hosts)
                deploy_root = _resolved_deploy_root_for_work(
                    proj; cli_override = remote,
                )
                record_deploy_status_for_run!(child_hosts, deploy_root, proj)
            end

            verify_go_slots_match_job!(
                proj,
                slots;
                remote_root = run_rr,
                julia = julia,
            )

            n_slots > 0 && _kit_progress_mark!("run")
            slot_run_ok = fill(false, n_slots)
            # `DISTSSH_JOBS` caps child SSH only. Parent slots stay concurrent.
            ssh_jobs = kit_host_jobs()
            ssh_permits = Channel{Nothing}(ssh_jobs)
            for _ in 1:ssh_jobs
                put!(ssh_permits, nothing)
            end
            @sync for i in 1:n_slots
                let i = i
                    @async begin
                        slot = slots[i]
                        child = slot.kind === :child
                        child && take!(ssh_permits)
                        try
                            kit_progress_item!(slot.label; status = :running)
                            outcome, err = try
                                (
                                    _go_exec_slot!(
                                        slot,
                                        proj,
                                        script_path,
                                        args,
                                        batch_dir,
                                        run_rr;
                                        quiet = quiet,
                                        julia = julia,
                                    ),
                                    nothing,
                                )
                            catch e
                                (
                                    (
                                        run = DriveResult(false, 1),
                                        collect = nothing,
                                        collect_fail = false,
                                    ),
                                    e,
                                )
                            end
                            slot_run_ok[i] = outcome.run.ok
                            lock(_GO_IO_LOCK) do
                                last_run[] = outcome.run
                                if !outcome.run.ok && first_fail_run[] === nothing
                                    first_fail_run[] = outcome.run
                                end
                                if err !== nothing
                                    any_run_fail[] = true
                                    kit_progress_item!(slot.label; status = :fail)
                                    _progress_release_line!()
                                    write(stderr, "  ")
                                    print_err("✗ $(slot.label): $(sprint(showerror, err))"; io = stderr)
                                    println(stderr)
                                elseif !outcome.run.ok
                                    any_run_fail[] = true
                                    kit_progress_item!(slot.label; status = :fail)
                                    _progress_release_line!()
                                    write(stderr, "  ")
                                    print_err(
                                        "✗ $(slot.label) (exit $(outcome.run.exit_code))$(_go_trace_suffix(outcome.run.output_dir))";
                                        io = stderr,
                                    )
                                    println(stderr)
                                else
                                    kit_progress_item!(slot.label; status = :ok)
                                    ok(slot.label)
                                end
                            end
                        finally
                            child && put!(ssh_permits, nothing)
                        end
                    end
                end
            end

            n_slots > 0 && _kit_progress_mark!("collect")
            slot_collect_ok = fill(false, n_slots)
            if !skip_collect
                collect_idx = Int[
                    i for (i, slot) in enumerate(slots) if
                        slot_run_ok[i] && slot.kind === :child
                ]
                _foreach_bounded(collect_idx, kit_host_jobs()) do i
                    slot = slots[i]
                    outcome, err = try
                        (
                            _go_collect_slot!(
                                slot, proj, batch_dir, run_rr; julia = julia,
                            ),
                            nothing,
                        )
                    catch e
                        ((collect = CollectResult(false, 1), collect_fail = true), e)
                    end
                    lock(_GO_IO_LOCK) do
                        if outcome.collect !== nothing
                            last_collect[] = outcome.collect
                        end
                        if err === nothing && outcome.collect !== nothing &&
                                outcome.collect.ok && !outcome.collect_fail
                            slot_collect_ok[i] = true
                        end
                        if outcome.collect_fail || err !== nothing
                            any_collect_fail[] = true
                        end
                        if err !== nothing
                            _progress_release_line!()
                            write(stderr, "  ")
                            print_err(
                                "✗ $(slot.label): $(sprint(showerror, err))";
                                io = stderr,
                            )
                            println(stderr)
                        end
                    end
                end
            end
            for (i, slot) in enumerate(slots)
                slot.kind === :child || continue
                slot_collect_ok[i] && continue
                host = slot.host::String
                slot_dir = joinpath(batch_dir, slot.label)
                slot_rel = _go_remote_slot_rel(proj, slot_dir, batch_dir, slot.label)
                _go_fetch_slot_provenance!(host, run_rr, slot_rel, slot_dir)
            end
            if any_run_fail[]
                completed = true
                return _go_complete!(
                    GoResult(
                        false,
                        sync_result,
                        something(first_fail_run[], last_run[]),
                        last_collect[],
                        script_path,
                        batch_dir;
                        failed_step = "run",
                    ),
                    batch_dir,
                    release_lock,
                    false,
                    proj,
                    anchor,
                    place,
                )
            end
            if any_collect_fail[]
                completed = true
                return _go_complete!(
                    GoResult(
                        false,
                        sync_result,
                        last_run[],
                        last_collect[],
                        script_path,
                        batch_dir;
                        failed_step = "collect",
                    ),
                    batch_dir,
                    release_lock,
                    false,
                    proj,
                    anchor,
                    place,
                )
            end

            writeln_both("")
            writeln_both("Results: $(display_path(batch_dir, anchor))")
            progress_ok = true
            completed = true
            return _go_complete!(
                GoResult(true, sync_result, last_run[], last_collect[], script_path, batch_dir),
                batch_dir,
                release_lock,
                true,
                proj,
                anchor,
                place,
            )
        finally
            # A throw after ship-tree registered hash tasks (for example
            # `instantiate_after_ship!`) never reaches the awaits above.
            try
                await_declared_input_hashes!()
            finally
                if !completed
                    footer = progress_ok ? display_path(batch_dir, anchor) : nothing
                    kit_progress_done!(; ok = progress_ok, footer = footer)
                    _print_go_slot_stdout_after_progress!(batch_dir)
                    _maybe_print_kit_progress_phases(batch_dir)
                    close_log_file()
                    _set_kit_progress_sidecar!(nothing)
                    release_lock()
                    _remove_kit_pid_file(getpid(), batch_dir, nothing)
                end
            end
        end
    end
end

function go!(script::AbstractString; kwargs...)::GoResult
    return go!(script, String[]; kwargs...)
end

function go!(
        script::AbstractString,
        w1::AbstractString,
        rest::AbstractString...;
        kwargs...,
    )::GoResult
    return go!(script, String[w1, rest...]; kwargs...)
end

"""
    report_go_errors(result::GoResult; io=stderr)

Print a short summary when [`go!`](@ref) failed. Returns `result.ok`.
"""
function report_go_errors(result::GoResult; io::IO = stderr)::Bool
    result.ok && return true
    _report_run_header!(io, kit_run_result(result))
    _report_sync_host_errors!(io, result.sync)
    if result.run !== nothing && !result.run.ok
        println(io, "  run exit $(result.run.exit_code)")
    end
    if result.collect !== nothing && !result.collect.ok
        println(io, "  collect exit $(result.collect.exit_code)")
    end
    return false
end

function report_run_errors(result::GoResult; io::IO = stderr)::Bool
    return report_go_errors(result; io = io)
end
