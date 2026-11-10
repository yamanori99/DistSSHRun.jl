# execute! — one seam over `go!` / `ride!` / `drive!` for callers that pick the kind at runtime
# (see https://github.com/yamanori99/DistSSHKit.jl/issues/129).
# Thin wrapper only: `go!` / `ride!` / `drive!` / `src/cli/*` are untouched.
# `detached=true` spawns `julia -m DistSSHKit go|ride|drive` and returns [`KitProcess`](@ref).

const _EXECUTE_DETACHED_KW = Set{Symbol}(
    (
        :quiet,
        :verbosity,
        :yes,
        :remote,
        :hosts_file,
        :log_dir,
        :enable_log,
        :package,
        :require_all_hosts,
        :skip_hash_check,
        :workers,
        :repeat,
        :stdout,
        :stderr,
        :job_id,
        :worker_include,
        :spi_check,
        :allow_mismatch,
        :allow_external_symlinks,
        :run_id,
    )
)
const _EXECUTE_DETACHED_DRIVE_ONLY = (
    :log_dir,
    :enable_log,
    :package,
    :require_all_hosts,
    :skip_hash_check,
    :workers,
    :worker_include,
)
const _EXECUTE_DETACHED_HARD_DROP = (
    "JULIA_LOAD_PATH",
    "DISTSSH_CLI_SUBCOMMAND_DONE",
    "DIST_SSH_KIT_CLI_INCLUDE",
)
# Removed from the child unless `threads=:unset`. `OPENBLAS_DEFAULT_NUM_THREADS`
# is dropped and not rewritten. The five BLAS names below are then set to `1`
# or to `DISTSSH_BLAS_THREADS`.
const _EXECUTE_DETACHED_THREAD_VARS = (
    "JULIA_NUM_THREADS",
    "JULIA_NUM_GC_THREADS",
    "OPENBLAS_NUM_THREADS",
    "OPENBLAS_DEFAULT_NUM_THREADS",
    "GOTO_NUM_THREADS",
    "OMP_NUM_THREADS",
    "MKL_NUM_THREADS",
    "MKL_DOMAIN_NUM_THREADS",
    "VECLIB_MAXIMUM_THREADS",
    "BLIS_NUM_THREADS",
)
const _EXECUTE_DETACHED_BLAS_SET = (
    "OPENBLAS_NUM_THREADS",
    "OMP_NUM_THREADS",
    "MKL_NUM_THREADS",
    "GOTO_NUM_THREADS",
    "VECLIB_MAXIMUM_THREADS",
)
const _EXECUTE_DETACHED_DENY_PARTS = (
    "SECRET",
    "PASSWORD",
    "PASSWD",
    "TOKEN",
    "API_KEY",
    "APIKEY",
    "ACCESS_KEY",
    "PRIVATE_KEY",
    "CREDENTIAL",
)
const _EXECUTE_DETACHED_PROXY_NAMES = (
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "no_proxy",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "NO_PROXY",
)
const _EXECUTE_DETACHED_BASELINE = (
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "TMPDIR",
    "TMP",
    "TEMP",
    "LANG",
    "LANGUAGE",
    "TZ",
    "TERM",
    "NO_COLOR",
    "JULIA_DEPOT_PATH",
    "JULIA_PKG_SERVER",
    "JULIA_PKG_SERVER_REGISTRY_PREFERENCE",
    "JULIA_PKG_OFFLINE",
    "JULIA_PKG_PRECOMPILE_AUTO",
    "JULIA_PKG_USE_CLI_GIT",
    "JULIA_SSL_CA_ROOTS_PATH",
    "JULIA_DISTRIBUTED_EXE",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "CURL_CA_BUNDLE",
    "GIT_SSL_CAINFO",
    "GIT_SSL_CAPATH",
    "GIT_SSH_COMMAND",
    "GIT_EXEC_PATH",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "no_proxy",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "NO_PROXY",
    "LD_LIBRARY_PATH",
    "DYLD_LIBRARY_PATH",
    "DYLD_FALLBACK_LIBRARY_PATH",
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID",
    "KRB5CCNAME",
    "XDG_RUNTIME_DIR",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "CUDA_VISIBLE_DEVICES",
    "NVIDIA_VISIBLE_DEVICES",
    "HIP_VISIBLE_DEVICES",
    "ROCR_VISIBLE_DEVICES",
    "GPU_DEVICE_ORDINAL",
)
const _EXECUTE_DETACHED_PROXY_USERINFO = r"^[A-Za-z][A-Za-z0-9+.-]*://[^/\s]*@"
# Reports for detached children. The process key keeps `KitProcess` construction unchanged.
const _DETACHED_LAUNCH = WeakKeyDict{Base.Process, NamedTuple}()
const _DETACHED_LAUNCH_LOCK = ReentrantLock()
# Named `execute!` kwargs (not in `_EXECUTE_DETACHED_KW`; they are not `kwargs...`).
const _EXECUTE_DETACHED_NAMED = (
    :output_dir,
    :args,
    :project,
    :sync,
    :julia,
    :detached,
    :source,
    :dir,
    :threads,
    :env_allow,
    :env,
)

"""
    execute_detached_accepts(kw; kind) -> Bool

Whether `execute!(kind, ...; detached=true)` accepts keyword `kw`.
Uses the same tables as the detached throw path, plus the named parameters
(`output_dir`, `args`, `project`, `sync`, `julia`, `detached`, `source`,
`dir`, `threads`, `env_allow`, `env`).
`source` is a provenance dict. Detached passes it to the child as
`DISTSSH_SOURCE_*`. It is not a `go!` / `ride!` / `drive!` keyword.
`dir`, `threads`, `env_allow`, and `env` are detached launch policy, not
`go!` / `ride!` / `drive!` keywords.
"""
function execute_detached_accepts(kw::Symbol; kind::Symbol)::Bool
    _require_execute_kind!(kind)
    kw in _EXECUTE_DETACHED_NAMED && return true
    kw in _EXECUTE_DETACHED_KW || return false
    kind === :go && return !(kw in _EXECUTE_DETACHED_DRIVE_ONLY) &&
        !(kw in (:spi_check,))
    kind === :ride && return !(
        kw in (
            :repeat, :worker_include, :package, :log_dir, :enable_log, :skip_hash_check,
            :workers, :require_all_hosts,
            :allow_external_symlinks,
        )
    )
    return !(kw in (:repeat, :spi_check))
end

# Copy `dir`, `threads`, `env_allow`, and `env` when `parsed` has a non-`nothing` value.
function _parsed_launch_kwargs!(kw::Dict{Symbol, Any}, parsed)
    for key in (:dir, :threads, :env_allow, :env)
        hasproperty(parsed, key) || continue
        value = getproperty(parsed, key)
        value === nothing && continue
        kw[key] = value
    end
    return kw
end

"""
    execute_kwargs_from_parsed(parsed; kind) -> Dict{Symbol,Any}

Keywords for [`execute!`](@ref) (`detached=true`) from `parse_go_args` /
`parse_drive_args` / `DistSSHRun.parse_ride_args`. Keys are a subset of [`execute_detached_accepts`](@ref).

Does not include `hosts_file` / `--hosts`: those tokens belong in
[`host_tokens`](@ref) (`kind` required). Does not set `project`, `detached`,
`yes`, `job_id`, `remote`, or stdio. Drive `--workers` is `:workers` only
when the parser set `default_workers`. `dir`, `threads`, `env_allow`, and
`env` are copied only when `parsed` has that property and the value is
not `nothing`. The go / drive / ride parsers do not grow those fields.
"""
function execute_kwargs_from_parsed(parsed; kind::Symbol)::Dict{Symbol, Any}
    _require_execute_kind!(kind)
    session = parsed.cli_session
    args = String[String(a) for a in parsed.script_args]
    kw = Dict{Symbol, Any}(
        :output_dir => parsed.output_dir,
        :args => args,
        :julia => parsed.julia,
        :quiet => session.quiet,
        :verbosity => session.verbosity,
    )
    am = get(parsed, :allow_mismatch, Symbol[])
    isempty(am) || (kw[:allow_mismatch] = am)
    snap0 = get(parsed, :run_id, nothing)
    snap0 === nothing || (kw[:run_id] = snap0)
    dr0 = get(parsed, :deploy_root, nothing)
    dr0 === nothing || (kw[:remote] = dr0)
    if kind === :go
        parsed.repeat === nothing || (kw[:repeat] = parsed.repeat)
        return _parsed_launch_kwargs!(kw, parsed)
    end
    if kind === :ride
        kw[:spi_check] = parsed.spi_check
        return _parsed_launch_kwargs!(kw, parsed)
    end
    kw[:log_dir] = parsed.log_dir
    kw[:enable_log] = parsed.enable_log
    kw[:package] = parsed.explicit_package
    kw[:require_all_hosts] = parsed.require_all_hosts
    kw[:skip_hash_check] = parsed.skip_hash_check
    get(parsed, :worker_include, false) && (kw[:worker_include] = true)
    dw = parsed.default_workers
    dw === nothing || (kw[:workers] = Int(dw))
    return _parsed_launch_kwargs!(kw, parsed)
end

"""
Handle to a detached [`execute!`](@ref) child (`detached=true`).

`process` is the `julia -m DistSSHKit go|drive|ride` subprocess.
`run_dir` is always allocated in the parent before spawn (pid / `kit.out` /
`run.toml`). Read it with [`result_run_dir`](@ref). The field is not API.
`output_dir` is the artifact root when known at spawn (`go` /
`ride`, explicit `output_dir=`, or inherited `DISTRIBUTED_OUTPUT_DIR`).
Detached `:drive` without those leaves `output_dir` as `nothing` so the child
can honor `init_output_dir!`. `log_dir` is `nothing` for `:go` / `:ride`.
[`wait`](@ref) returns a [`KitRunResult`](@ref); it does not fill
`output_dir` on this handle.
"""
struct KitProcess
    process::Base.Process
    kind::Symbol
    output_dir::Union{Nothing, String}
    log_dir::Union{Nothing, String}
    stdout_owned::Union{Nothing, IO}
    stderr_owned::Union{Nothing, IO}
    run_dir::Union{Nothing, String}
end

function KitProcess(
        process::Base.Process;
        kind::Symbol,
        output_dir::Union{Nothing, AbstractString} = nothing,
        log_dir::Union{Nothing, AbstractString} = nothing,
        stdout_owned::Union{Nothing, IO} = nothing,
        stderr_owned::Union{Nothing, IO} = nothing,
        run_dir::Union{Nothing, AbstractString} = nothing,
    )
    _require_execute_kind!(kind)
    return KitProcess(
        process, kind, _optional_path(output_dir), _optional_path(log_dir),
        stdout_owned, stderr_owned, _optional_path(run_dir),
    )
end

"""
    detached_launch(kp::KitProcess) -> NamedTuple

`(dir, threads, dropped, sensitive)` for a detached [`execute!`](@ref) child.

`dir` is the child working directory. `threads` is the `--threads` value,
or `"unset"` when that flag was omitted. `dropped` is the sorted list of
parent environment names that were not passed through. `sensitive` is the
sorted list of names the caller set with `env_allow` or `env` even though
they match the secret-name denylist. Values are not included.

A handle this function did not record returns `dir=""`, `threads="unset"`,
and empty lists. Local go slots and local drive workers inherit the child
environment, so a kept `SSH_AUTH_SOCK` reaches them. SSH workers do not
receive this process's agent socket.
"""
function detached_launch(kp::KitProcess)
    return lock(_DETACHED_LAUNCH_LOCK) do
        found = get(_DETACHED_LAUNCH, kp.process, nothing)
        found === nothing && return (
            dir = "",
            threads = "unset",
            dropped = String[],
            sensitive = String[],
        )
        return (
            dir = String(found.dir),
            threads = String(found.threads),
            dropped = String[String(x) for x in found.dropped],
            sensitive = String[String(x) for x in found.sensitive],
        )
    end
end

function _remember_detached_launch!(proc::Base.Process, report)
    stored = (
        dir = String(report.dir),
        threads = String(report.threads),
        dropped = String[String(x) for x in report.dropped],
        sensitive = String[String(x) for x in report.sensitive],
    )
    return lock(_DETACHED_LAUNCH_LOCK) do
        _DETACHED_LAUNCH[proc] = stored
        return nothing
    end
end

function _close_owned_stdio!(kp::KitProcess)
    for io in (kp.stdout_owned, kp.stderr_owned)
        io === nothing && continue
        try
            close(io)
        catch
        end
    end
    return nothing
end

"""
    wait(kp::KitProcess; timeout=nothing) -> KitRunResult

Block until the detached child exits, then return a [`KitRunResult`](@ref).

Does not mutate `kp.output_dir` / `kp.log_dir`. After a detached `:drive`
that deferred the artifact leaf, read the returned result (or
[`kit_result_from_dir`](@ref) / [`read_kit_run_toml`](@ref) on the
directory from [`result_run_dir`](@ref)).

`timeout` is wall-clock seconds until the **child process** exits (not the
drive worker heartbeat). `nothing` waits forever. On timeout the child is
left running: `failed_step` is `"hung"`, `exit_code` is `124`, and owned
stdio stays open. Call [`terminate!`](@ref) if the hang is fatal.

If the child wrote `kit.result` under `run_dir` or `output_dir`, that file is
the source of truth (including `failed_step` from `go!` / `ride!`). Otherwise
`failed_step` is `"go"` / `"ride"` / `"drive"` on a non-zero exit — the parent
cannot recover a more specific in-process step name.

Best-effort: remove `kit.pid` if it still names this child (pid captured
before `wait` on the OS process; after reap `getpid` can throw ESRCH).
Not on a hung timeout.
"""
function Base.wait(
        kp::KitProcess;
        timeout::Union{Nothing, Real} = nothing,
    )::KitRunResult
    timeout !== nothing && timeout < 0 && throw(
        ArgumentError(
            "wait timeout must be ≥ 0, got $timeout",
        )
    )
    child_pid = try
        Int(getpid(kp.process))
    catch
        nothing
    end
    if timeout !== nothing && process_running(kp.process)
        t0 = time()
        while process_running(kp.process) && (time() - t0) < Float64(timeout)
            sleep(0.05)
        end
        if process_running(kp.process)
            return KitRunResult(
                false, kp.kind, kp.output_dir, kp.log_dir, "hung", 124;
                run_dir = kp.run_dir,
            )
        end
    end
    try
        wait(kp.process)
        recovered = _kit_result_from_process(kp)
        child_pid !== nothing && _remove_kit_pid_file(
            child_pid, kp.output_dir, kp.log_dir; run_dir = kp.run_dir,
        )
        recovered !== nothing && return recovered
        code = DistSSHBase.shell_status(kp.process)
        ok = code == 0
        return KitRunResult(
            ok,
            kp.kind,
            kp.output_dir,
            kp.log_dir,
            ok ? nothing : String(kp.kind),
            code;
            run_dir = kp.run_dir,
        )
    finally
        _close_owned_stdio!(kp)
    end
end

"""
    execute!(kind, script, tokens=String[]; output_dir=nothing, args=String[], project=pwd(), sync=nothing, julia=nothing, detached=false, source=nothing, kwargs...) -> KitRunResult or KitProcess

One seam over [`go!`](@ref) / [`ride!`](@ref) / [`drive!`](@ref) for callers
that pick the kind at runtime (`kind ∈ (:go, :ride, :drive)`), returning the
shared [`KitRunResult`](@ref) instead of `GoResult` / `RideResult` / `DriveResult`.

```julia
execute!(:go, "job.jl", ["parent:2"]; args=["8"])
execute!(:ride, "job.jl", ["parent:2"])
execute!(:drive, "job.jl", ["parent:2"]; args=["8"])
wait(execute!(:go, "job.jl", ["parent:1"]; detached=true, args=["8"]))
```

`output_dir`, `args`, `project`, `sync`, `julia` are the keywords [`go!`](@ref)
and [`drive!`](@ref) already share (`ride!` ignores `sync`). With `detached=false`
(default), any other keyword is forwarded to the chosen function.

`detached=true` spawns `julia -m DistSSHKit go|ride|drive` and returns a
[`KitProcess`](@ref). `sync=:ship_tree` or `sync=:git_sync` is an error before
spawn (run no longer transfers). Ship or git-sync first with [`setup!`](@ref)
`:ship_tree` / `:git_sync`, or CLI `setup ship-tree` / `setup git-sync`.
A script outside the project is `extra_files=[script]` (one file, at
`_distsshrun_external/<basename>`), then `setup!(session, :instantiate; run_id=id)`,
then `execute!(...; run_id=id)` with that same local script.
In-process [`go!`](@ref) / [`drive!`](@ref) reject `sync=:ship_tree` and
`sync=:git_sync` the same way. Omitted/`false` `sync` and `run_id=` are
unchanged.
`--project=` is always the job `project=` when that
tree has a `Project.toml`. The job must list DistSSHKit or DistSSHRun in
`[deps]`; otherwise this throws instead of using serve's active project.
Keywords are then an allow-list (unknown names throw):
`output_dir`, `args`, `project`, `sync`, `julia`, `quiet`, `verbosity`, `yes`,
`remote`, `hosts_file`, `job_id`, `source`, `allow_mismatch`, and drive-only `log_dir`,
`enable_log`, `package`, `require_all_hosts`, `skip_hash_check`,
`workers`, `worker_include`,
`allow_external_symlinks`, `dir`, `threads`, `env_allow`, and `env`.
`source` is a provenance
dict for every kind. Detached passes it as `DISTSSH_SOURCE_*`. Go-only
`repeat`. Ride: `spi_check` (default
`false`). Detached argv passes `--spi-check` when true and `--no-spi-check`
when false, so an older child whose default is on still skips the compare.
Neither go nor
ride takes sizing flags. `yes` must be `true` (the
default): an unattended child cannot answer a prompt. `remote` that starts
with `~` is stored in `DISTRIBUTED_REMOTE_PROJECT_ROOT` as a layout path
(not `expanduser` on the kit parent). Child stdio defaults to
`kit.out` / `kit.err` in `run_dir`. Pass `stdout` / `stderr` (`IO`) to
override; `stdout=stdout` inherits the parent. Parent `redirect_stdout` does
not apply to the subprocess. Detached `:drive` omits `--output-dir` unless
`output_dir=` or inherited `DISTRIBUTED_OUTPUT_DIR` is set, so
`init_output_dir!` can choose the artifact root.

`job_id`, if given, is passed to the child as `DISTSSH_JOB_ID`, which
adds `job=<id>` to every `progress:` log line. `DISTSSH_PROGRESS=1` is
`--progress` verbosity, not a watcher; read lines with
`DistSSHRun.parse_progress_line` / `DistSSHRun.kit_progress_latest`.
Omitted entirely when unset.

The detached child starts in `dir` (default: the `project` directory) and
passes `--history-file=no`. `threads` defaults to `1`, passed as
`--threads=1` (`Threads.nthreads(:interactive)` is 0 on Julia 1.13).
`threads=:inherit` passes this process's resolved `--threads` spec.
`threads=:unset` omits the flag. The child environment keeps an allowlist
(`PATH`, `HOME`, `JULIA_DEPOT_PATH`, `DISTSSH_*`, `DISTRIBUTED_*`, and
the other baseline names). `env_allow` adds names to that baseline.
`:all` copies every non-empty parent variable except the drops below.
`env` sets values on the child and does not write this process. Names
containing `COOKIE`, `JULIA_LOAD_PATH`, and the CLI include guards are
never copied. A recognized proxy value that contains userinfo
(`http_proxy`, `https_proxy`, `all_proxy`, `no_proxy`, and the uppercase
names) is dropped unless that name is in `env_allow` or `env`. A
case-sensitive substring denylist (`SECRET`, `PASSWORD`, `PASSWD`,
`TOKEN`, `API_KEY`, `APIKEY`, `ACCESS_KEY`, `PRIVATE_KEY`, `CREDENTIAL`)
drops baseline, prefix, and `:all` copies. An explicit `env_allow` or
`env` name wins and is recorded as sensitive. A count of dropped names
is logged. The names, not the values, are in [`detached_launch`](@ref),
`run.toml` `[launch]`, and the debug log (`JULIA_DEBUG=DistSSHRun`).
`schema` stays 1.

Local go slots and local drive workers inherit that environment, including
`SSH_AUTH_SOCK` when it was kept. SSH workers do not receive this
process's agent socket. A `drive --isolated` grandchild inherits the
filtered environment. In-process `execute!` and `julia -m DistSSHKit` do
not use this policy.

```julia
execute!(kind, script, tokens; detached=true, dir=pwd(), threads=:unset, env_allow=:all)
```

That restore still drops `JULIA_LOAD_PATH`, the CLI include guards, names
that contain `COOKIE`, names that contain a denylist substring, and a
recognized proxy value that contains userinfo. Set a denylisted name or
such a proxy value with `env`, or name it in an `env_allow` list. The
list keeps the baseline and those names. It does not copy the rest of
the parent environment. `JULIA_LOAD_PATH`, the CLI include guards, and
names that contain `COOKIE` cannot be passed that way.
"""
function execute!(
        kind::Symbol,
        script::AbstractString,
        tokens::AbstractVector{<:AbstractString} = String[];
        output_dir::Union{Nothing, AbstractString} = nothing,
        args::AbstractVector{<:AbstractString} = String[],
        project::AbstractString = pwd(),
        sync::Union{Symbol, Bool, Nothing} = nothing,
        julia::Union{Nothing, AbstractString} = nothing,
        detached::Bool = false,
        source::Union{Nothing, AbstractDict} = nothing,
        dir::Union{Nothing, AbstractString} = nothing,
        threads::Union{Integer, AbstractString, Symbol} = 1,
        env_allow = nothing,
        env::Union{Nothing, AbstractDict} = nothing,
        kwargs...,
    )
    _require_execute_kind!(kind)
    if detached
        return _execute_detached!(
            kind,
            script,
            tokens;
            output_dir = output_dir,
            args = args,
            project = project,
            sync = sync,
            julia = julia,
            source = source,
            dir = dir,
            threads = threads,
            env_allow = env_allow,
            env = env,
            kwargs...,
        )
    end
    _reject_inprocess_launch!(dir, threads, env_allow, env)
    _reject_run_transfer_kw!("execute!", sync; surface = :api)
    get(kwargs, :allow_external_symlinks, false) === true &&
        _reject_run_transfer_cli!("execute!", "--allow-external-symlinks")
    _set_provenance_source!(source)
    result = try
        if kind === :go
            go!(
                script,
                tokens;
                output_dir = output_dir,
                args = args,
                project = project,
                julia = julia,
                kwargs...,
            )
        elseif kind === :ride
            (sync === nothing || sync === false) || throw(
                ArgumentError(
                    "execute!(:ride, ...) does not accept sync=$(repr(sync))",
                )
            )
            ride!(
                script,
                tokens;
                output_dir = output_dir,
                args = args,
                project = project,
                julia = julia,
                kwargs...,
            )
        else
            drive!(
                script,
                tokens;
                output_dir = output_dir,
                args = args,
                project = project,
                julia = julia,
                kwargs...,
            )
        end
    finally
        _set_provenance_source!(nothing)
    end
    return kit_run_result(result)
end

function _parse_toml_dict(path::AbstractString)
    isfile(path) || return nothing
    raw = try
        TOML.parsefile(String(path))
    catch
        return nothing
    end
    return raw isa AbstractDict ? raw : nothing
end

function _deps_has_name(raw, name::AbstractString)::Bool
    raw isa AbstractDict || return false
    deps = get(raw, "deps", nothing)
    return deps isa AbstractDict && haskey(deps, name)
end

function _deps_has_distsshkit(raw)::Bool
    return _deps_has_name(raw, "DistSSHKit") || _deps_has_name(raw, "DistSSHRun")
end

"""Whether a job tree can load `-m` via `--project=` at `project`.

`julia -m` needs the named package or a **direct** `[deps]` entry.
`Manifest.toml` is a flat resolved graph; a `DistSSHRun` entry there can be
transitive (e.g. via DistSSHQueue) and does not mean `--project=` can load it
with `-m` (#372). The job package itself named DistSSHKit / DistSSHRun can
`-m`. A direct `DistSSHKit` dep loads `-m DistSSHKit`. A direct `DistSSHRun`
dep loads `-m DistSSHRun`."""
function _project_tree_has_distsshkit(project::AbstractString)::Bool
    p = string(project)::String
    n = project_package_name(p)
    (n == "DistSSHRun" || n == "DistSSHKit") && return true
    return _deps_has_distsshkit(_parse_toml_dict(joinpath(p, "Project.toml")))
end

"""`--project=` for a detached child.

Always the job `project=` when that tree has a `Project.toml`. Do not fall
back to serve's active project or `pkgdir(DistSSHRun)`. If the job cannot
load `-m DistSSHKit` / `-m DistSSHRun`, fail instead of using queue-env.
"""
function _detached_julia_project(project::AbstractString)::String
    p = string(project)::String
    isfile(joinpath(p, "Project.toml")) || throw(
        ArgumentError(
            "detached execute! project has no Project.toml: $(p)",
        ),
    )
    _project_tree_has_distsshkit(p) || throw(
        ArgumentError(
            "detached execute! project $(p) does not list DistSSHKit or DistSSHRun in [deps]; cannot -m from the job tree",
        ),
    )
    return p
end

"""`-m` package for a detached child.

Users add DistSSHKit. Main loads only a direct `[deps]` name, so a
transitive DistSSHRun cannot be `-m`'d. DistSSHKit when that name is in
`[deps]`, otherwise DistSSHRun.

`project` is the directory passed to `--project=`, from
`_detached_julia_project` (the job tree)."""
function _detached_m_package(project::AbstractString)::String
    p = String(project)
    project_package_name(p) == "DistSSHKit" && return "DistSSHKit"
    raw = _parse_toml_dict(joinpath(p, "Project.toml"))
    _deps_has_name(raw, "DistSSHKit") && return "DistSSHKit"
    return "DistSSHRun"
end

function _execute_detached!(
        kind::Symbol,
        script::AbstractString,
        tokens::AbstractVector{<:AbstractString};
        output_dir::Union{Nothing, AbstractString},
        args::AbstractVector{<:AbstractString},
        project::AbstractString,
        sync::Union{Symbol, Bool, Nothing},
        julia::Union{Nothing, AbstractString},
        source::Union{Nothing, AbstractDict} = nothing,
        dir::Union{Nothing, AbstractString} = nothing,
        threads::Union{Integer, AbstractString, Symbol} = 1,
        env_allow = nothing,
        env::Union{Nothing, AbstractDict} = nothing,
        kwargs...,
    )::KitProcess
    for k in keys(kwargs)
        k in _EXECUTE_DETACHED_KW || throw(
            ArgumentError(
                "execute!(...; detached=true) does not accept keyword $(repr(k))",
            )
        )
    end
    if kind === :go
        for k in _EXECUTE_DETACHED_DRIVE_ONLY
            haskey(kwargs, k) && throw(
                ArgumentError(
                    "execute!(:go, ...; detached=true) does not accept keyword $(repr(k))",
                )
            )
        end
        haskey(kwargs, :spi_check) && throw(
            ArgumentError(
                "execute!(:go, ...; detached=true) does not accept keyword :spi_check",
            )
        )
    elseif kind === :ride
        haskey(kwargs, :repeat) && throw(
            ArgumentError(
                "execute!(:ride, ...; detached=true) does not accept keyword :repeat",
            )
        )
        for k in (
                :worker_include, :package, :log_dir, :enable_log, :skip_hash_check,
                :workers, :require_all_hosts,
                :allow_external_symlinks,
            )
            haskey(kwargs, k) && throw(
                ArgumentError(
                    "execute!(:ride, ...; detached=true) does not accept keyword $(repr(k))",
                )
            )
        end
        (sync === nothing || sync === false) || throw(
            ArgumentError(
                "execute!(:ride, ...; detached=true) does not accept sync=$(repr(sync))",
            )
        )
    elseif kind === :drive
        haskey(kwargs, :repeat) && throw(
            ArgumentError(
                "execute!(:drive, ...; detached=true) does not accept keyword :repeat",
            )
        )
        haskey(kwargs, :spi_check) && throw(
            ArgumentError(
                "execute!(:drive, ...; detached=true) does not accept keyword :spi_check",
            )
        )
    end
    _reject_run_transfer_kw!("execute!", sync; surface = :api)
    get(kwargs, :allow_external_symlinks, false) === true &&
        _reject_run_transfer_cli!("execute!", "--allow-external-symlinks")
    yes = get(kwargs, :yes, true)
    yes === true || throw(ArgumentError("execute!(...; detached=true) requires yes=true"))
    quiet = get(kwargs, :quiet, false)
    quiet isa Bool || throw(ArgumentError("quiet must be a Bool, got $(repr(quiet))"))
    verbosity = get(kwargs, :verbosity, nothing)
    if verbosity !== nothing && !(verbosity isa Symbol)
        throw(ArgumentError("verbosity must be a Symbol or nothing, got $(repr(verbosity))"))
    end
    remote = get(kwargs, :remote, nothing)
    hosts_file = get(kwargs, :hosts_file, nothing)
    log_dir = get(kwargs, :log_dir, nothing)
    enable_log = get(kwargs, :enable_log, true)
    package = get(kwargs, :package, nothing)
    require_all_hosts = get(kwargs, :require_all_hosts, true)
    if kind === :drive
        require_all_hosts isa Bool || throw(
            ArgumentError(
                "require_all_hosts must be a Bool, got $(repr(require_all_hosts))",
            )
        )
    end
    skip_hash_check = get(kwargs, :skip_hash_check, true)
    workers = get(kwargs, :workers, nothing)
    repeat = get(kwargs, :repeat, nothing)
    get(kwargs, :sync_script, nothing) !== nothing &&
        _reject_removed_drive_worker_include_kw!(true)
    worker_include = get(kwargs, :worker_include, false)
    spi_check = get(kwargs, :spi_check, false)
    allow_mismatch = get(kwargs, :allow_mismatch, Symbol[])
    allow_external_symlinks = get(kwargs, :allow_external_symlinks, false)
    run_id = get(kwargs, :run_id, nothing)
    if run_id !== nothing
        run_id = validate_run_id(run_id)
    end
    worker_include isa Bool || throw(
        ArgumentError(
            "worker_include must be a Bool, got $(repr(worker_include))",
        )
    )
    spi_check isa Bool || throw(
        ArgumentError(
            "spi_check must be a Bool, got $(repr(spi_check))",
        )
    )
    if workers !== nothing
        (workers isa Integer && !(workers isa Bool)) || throw(
            ArgumentError(
                "workers must be an integer, got $(repr(workers))",
            )
        )
        w = Int(workers)
        w < 1 && throw(ArgumentError("workers must be >= 1, got $w"))
        workers = w
    end
    if repeat !== nothing
        (repeat isa Integer && !(repeat isa Bool)) || throw(
            ArgumentError(
                "repeat must be an integer, got $(repr(repeat))",
            )
        )
        r = Int(repeat)
        r < 1 && throw(ArgumentError("repeat must be >= 1, got $r"))
        repeat = r
    end

    if output_dir !== nothing
        output_dir = _prepare_output_dir!(String(output_dir); command = kind, surface = :api)
    end
    proj = canonical_local_path(project)
    launch_dir = _detached_launch_dir(dir, proj)
    script_path = _remote_script_argv(script) ? String(script) : canonical_local_path(script)
    job_id = get(kwargs, :job_id, nothing)
    job_id_s = if job_id !== nothing && !isempty(strip(String(job_id)))
        _parse_kit_job_id(String(job_id))
    else
        nothing
    end
    run_dir = allocate_run_dir(
        kind, script_path; project = proj, job_id = job_id_s,
    )
    resolved_output, resolved_log = _execute_detached_dirs(
        kind,
        proj,
        script_path,
        output_dir,
        log_dir,
        enable_log,
        run_dir,
    )
    argv = _execute_detached_argv(
        kind,
        script_path,
        tokens,
        args;
        output_dir = resolved_output,
        log_dir = resolved_log,
        sync = sync,
        julia = julia,
        quiet = quiet,
        verbosity = verbosity,
        hosts_file = hosts_file,
        enable_log = enable_log,
        package = package,
        require_all_hosts = require_all_hosts,
        skip_hash_check = skip_hash_check,
        workers = workers,
        repeat = repeat,
        worker_include = worker_include,
        spi_check = spi_check,
        allow_mismatch = allow_mismatch,
        allow_external_symlinks = allow_external_symlinks === true,
        run_id = run_id,
        remote = remote,
    )
    extra = Dict{String, String}(
        "DISTRIBUTED_PROJECT_ROOT" => proj,
        DISTSSH_RUN_DIR_ENV => run_dir,
    )
    if remote !== nothing && !isempty(strip(String(remote)))
        extra["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = remote_env_project_root(String(remote))
    end
    if job_id_s !== nothing
        extra["DISTSSH_JOB_ID"] = job_id_s
    end
    for (envk, envv) in _provenance_source_env(source)
        extra[envk] = envv
    end
    built = _detached_child_env(
        ENV, extra;
        threads = threads,
        env_allow = env_allow,
        env = env,
        launch_dir = launch_dir,
        source = source,
    )
    _log_detached_dropped!(built.dropped)
    julia_bin = resolve_controller_julia(julia)
    child_proj = _detached_julia_project(proj)
    julia_argv = String[
        julia_bin,
        "--startup-file=no",
        "--history-file=no",
    ]
    built.threads == "unset" || push!(julia_argv, "--threads=$(built.threads)")
    push!(
        julia_argv,
        "--project=$(child_proj)",
        "-m",
        _detached_m_package(child_proj),
    )
    append!(julia_argv, argv)
    child = ignorestatus(setenv(Cmd(julia_argv), built.env; dir = launch_dir))
    stdio_out, stdio_err, owned_out, owned_err = _execute_detached_stdio(kwargs, run_dir)
    proc = try
        run(pipeline(child; stdout = stdio_out, stderr = stdio_err); wait = false)
    catch
        for io in (owned_out, owned_err)
            io === nothing || close(io)
        end
        rethrow()
    end
    _remember_detached_launch!(
        proc,
        (
            dir = launch_dir,
            threads = built.threads,
            dropped = built.dropped,
            sensitive = built.sensitive,
        ),
    )
    _write_detached_kit_pid_file!(
        proc, resolved_output, resolved_log;
        job_id = job_id_s,
        run_dir = run_dir,
    )
    return KitProcess(
        proc;
        kind = kind,
        output_dir = resolved_output,
        log_dir = resolved_log,
        stdout_owned = owned_out,
        stderr_owned = owned_err,
        run_dir = run_dir,
    )
end

"""Open `kit.out` / `kit.err` under `run_dir` when `stdout` / `stderr` are omitted."""
function _execute_detached_stdio(kwargs, run_dir::AbstractString)
    stdio_out = get(kwargs, :stdout, nothing)
    stdio_err = get(kwargs, :stderr, nothing)
    owned_out = nothing
    owned_err = nothing
    if stdio_out === nothing
        mkpath(run_dir)
        owned_out = open(joinpath(run_dir, "kit.out"), "w")
        stdio_out = owned_out
    end
    if stdio_err === nothing
        mkpath(run_dir)
        owned_err = open(joinpath(run_dir, "kit.err"), "w")
        stdio_err = owned_err
    end
    return stdio_out, stdio_err, owned_out, owned_err
end

"""Write `kit.pid` only while this `Base.Process` is still running.

If the child already exited (and likely removed the file), skip the write.
After the write, drop the file again if this process has reaped — so a
recycled OS pid is not left for [`kit_pid_file_running`](@ref).
"""
function _write_detached_kit_pid_file!(
        proc::Base.Process,
        output_dir::Union{Nothing, AbstractString},
        log_dir::Union{Nothing, AbstractString};
        job_id::Union{Nothing, AbstractString} = nothing,
        run_dir::Union{Nothing, AbstractString} = nothing,
    )
    process_running(proc) || return nothing
    child_pid = try
        Int(getpid(proc))
    catch
        return nothing
    end
    _write_kit_pid_file(
        child_pid, output_dir, log_dir;
        job_id = job_id,
        run_dir = run_dir,
    )
    process_running(proc) && return nothing
    _remove_kit_pid_file(child_pid, output_dir, log_dir; run_dir = run_dir)
    return nothing
end

"""
Best-effort `kit.pid` drop in `output_dir` (and `log_dir` if distinct) holding
the detached child's OS pid as plain text.

Lets a caller that lost its in-memory [`KitProcess`](@ref) (e.g. a queue
service restarted while a job was running) re-check liveness later via
`kill(pid, 0)` / equivalent, without any other change to `execute!`. Never
throws: a failure here must not fail the spawn that already happened.

The child removes the file in `go!` / `drive!` `finally` when it still names
this pid (same rule as `.kit.lock`). [`wait`](@ref) does the same as backup
when the caller still has a [`KitProcess`](@ref). SIGKILL / crash can leave
the file; a reused pid can then look alive.
"""
function _kit_sidecar_dirs(
        output_dir::Union{Nothing, AbstractString},
        log_dir::Union{Nothing, AbstractString};
        run_dir::Union{Nothing, AbstractString} = kit_run_dir(),
    )
    dirs = String[]
    function add!(p)
        p === nothing && return nothing
        s = String(p)
        isempty(strip(s)) && return nothing
        for d in dirs
            d == s && return nothing
        end
        push!(dirs, s)
        return nothing
    end
    add!(run_dir)
    add!(output_dir)
    add!(log_dir)
    return dirs
end

function _write_kit_pid_file(
        pid::Integer,
        output_dir::Union{Nothing, AbstractString},
        log_dir::Union{Nothing, AbstractString};
        job_id::Union{Nothing, AbstractString} = nothing,
        run_dir::Union{Nothing, AbstractString} = kit_run_dir(),
    )
    dirs = _kit_sidecar_dirs(output_dir, log_dir; run_dir = run_dir)
    for d in dirs
        try
            mkpath(d) # child creates it too, but may not have raced ahead of us yet
            if run_dir !== nothing && !isempty(strip(String(run_dir)))
                write(
                    joinpath(d, "kit.run_dir"),
                    canonical_local_path(String(run_dir)) * "\n",
                )
            end
            path = joinpath(d, "kit.pid")
            body = sprint() do io
                println(io, Int(pid))
                st = kit_process_start_key(Int(pid))
                if st !== nothing
                    println(io, st)
                end
            end
            write(path, body)
            if job_id !== nothing && !isempty(strip(String(job_id)))
                try
                    write(joinpath(d, "kit.job"), strip(String(job_id)))
                catch
                end
            end
        catch
            # best-effort only
        end
    end
    return nothing
end

function _write_kit_text_file!(
        name::AbstractString,
        body::AbstractString,
        output_dir::AbstractString,
        log_dir::Union{Nothing, AbstractString},
    )
    for d in _kit_sidecar_dirs(output_dir, log_dir)
        try
            mkpath(d)
            write(joinpath(d, name), body)
        catch
        end
    end
    return nothing
end

"""Best-effort host list for [`terminate_run!`](@ref) (SSH names, one per line)."""
function _write_kit_hosts_file(
        hosts::AbstractVector{<:AbstractString},
        output_dir::AbstractString,
        log_dir::Union{Nothing, AbstractString},
    )
    isempty(hosts) && return nothing
    names = unique!(String[String(h) for h in hosts])
    body = sprint() do io
        for h in names
            println(io, h)
        end
    end
    _write_kit_text_file!("kit.hosts", body, output_dir, log_dir)
    return nothing
end

"""Remove `kit.hosts` from the same directories as [`_write_kit_hosts_file`](@ref)."""
function _remove_kit_hosts_file(
        output_dir::AbstractString,
        log_dir::Union{Nothing, AbstractString},
    )
    for d in _kit_sidecar_dirs(output_dir, log_dir)
        try
            rm(joinpath(d, "kit.hosts"); force = true)
        catch
        end
    end
    return nothing
end

const DRIVE_HOST_WORKER_IDS = Dict{String, Vector{Int}}()
const DRIVE_HOST_LAST_SEEN = Dict{String, Float64}()
const DRIVE_HOST_STATUS_STOP = Ref(true)
const DRIVE_HOST_STATUS_TASK = Ref{Union{Nothing, Task}}(nothing)

function _clear_drive_host_worker_ids!()
    empty!(DRIVE_HOST_WORKER_IDS)
    empty!(DRIVE_HOST_LAST_SEEN)
    return nothing
end

function _drive_host_status_monitor_active()::Bool
    t = DRIVE_HOST_STATUS_TASK[]
    return t !== nothing && !istaskdone(t) && !DRIVE_HOST_STATUS_STOP[]
end

function _require_drive_host_status_idle!()
    if _drive_host_status_monitor_active()
        throw(
            ArgumentError(
                "overlapping in-process drive!/ride! is not supported (host-status monitor already running)",
            )
        )
    end
    return nothing
end

function _register_drive_host_worker_ids!(host::AbstractString, ids::AbstractVector{<:Integer})
    DRIVE_HOST_WORKER_IDS[String(host)] = Int[Int(i) for i in ids]
    return nothing
end

"""Host name for a worker that `addprocs` created but did not register.

Local workers stay on the parent. An SSH worker uses the host in its
`WorkerConfig`, without a `user@` prefix. Anything else is `unknown`, not the parent.
"""
function _leftover_worker_host(pid::Integer)::String
    ep = _interrupt_endpoint(pid)
    ep === :local && return PARENT_HOST_NAME
    if ep isa Tuple
        host = String(ep[1])
        at = findlast('@', host)
        return at === nothing ? host : String(host[nextind(host, at):end])
    end
    return "unknown"
end

"""Append unregistered workers to the host they belong to. Does not replace a host list."""
function _register_leftover_workers!(pids::AbstractVector{<:Integer})
    isempty(pids) && return nothing
    by_host = Dict{String, Vector{Int}}()
    for pid in pids
        host = _leftover_worker_host(pid)
        push!(get!(by_host, host, Int[]), Int(pid))
    end
    for (host, ids) in by_host
        existing = Int[Int(i) for i in get(DRIVE_HOST_WORKER_IDS, String(host), Int[])]
        _register_drive_host_worker_ids!(host, vcat(existing, ids))
    end
    return nothing
end

function _drive_parent_worker_count()::Int
    ids = get(DRIVE_HOST_WORKER_IDS, PARENT_HOST_NAME, Int[])
    return length(ids)
end

"""SSH workers sleep `DISTRIBUTED_INIT_DELAY_SEC` (default 5). Local-only is 0."""
function _drive_init_delay_sec(; ssh::Bool)::Float64
    ssh || return 0.0
    d = tryparse(Float64, get(ENV, "DISTRIBUTED_INIT_DELAY_SEC", "5"))
    d === nothing && return 0.0
    return d > 0 ? d : 0.0
end

"""Hosts whose registered workers are no longer alive (`:left`)."""
function _drive_hosts_that_left()::Vector{String}
    left = String[]
    for host in sort!(collect(keys(DRIVE_HOST_WORKER_IDS)))
        if _probe_drive_host(DRIVE_HOST_WORKER_IDS[host]) !== :alive
            push!(left, host)
        end
    end
    return left
end

function _drive_host_span!(host::AbstractString, leaf::AbstractString, status::Symbol)
    _kit_progress_span!(string(host, "/", leaf), status)
    return nothing
end

function _last_seen_for(host::AbstractString)::Union{Nothing, Float64}
    h = String(host)
    return haskey(DRIVE_HOST_LAST_SEEN, h) ? DRIVE_HOST_LAST_SEEN[h] : nothing
end

"""`:alive` if any registered worker id is still in `Distributed.workers()`, else `:left`."""
function _probe_drive_host(ids::AbstractVector{<:Integer})::Symbol
    live = workers()
    for w in ids
        wid = Int(w)
        for x in live
            x == wid && return :alive
        end
    end
    return :left
end

function _write_kit_hosts_status_file(
        rows::AbstractVector{DriveHostStatus},
        output_dir::AbstractString,
        log_dir::Union{Nothing, AbstractString},
    )
    tables = Vector{Dict{String, Any}}()
    for r in rows
        d = Dict{String, Any}("host" => r.host, "state" => String(r.state))
        r.last_seen !== nothing && (d["last_seen"] = r.last_seen)
        push!(tables, d)
    end
    data = Dict{String, Any}("hosts" => tables)
    for d in _kit_sidecar_dirs(output_dir, log_dir)
        try
            mkpath(d)
            dest = joinpath(d, "kit.hosts.status")
            tmp = dest * ".tmp"
            open(tmp, "w") do io
                TOML.print(io, data)
            end
            mv(tmp, dest; force = true)
        catch
        end
    end
    return nothing
end

function _write_joined_drive_host_status!(
        hosts::AbstractVector{<:AbstractString},
        output_dir::AbstractString,
        log_dir::Union{Nothing, AbstractString},
    )
    rows = DriveHostStatus[DriveHostStatus(String(h), :joined, nothing) for h in unique(hosts)]
    isempty(rows) && return nothing
    _write_kit_hosts_status_file(rows, output_dir, log_dir)
    return nothing
end

function _refresh_drive_host_status_file!(
        output_dir::AbstractString,
        log_dir::Union{Nothing, AbstractString};
        now::Float64 = time(),
    )
    rows = DriveHostStatus[]
    for host in sort!(collect(keys(DRIVE_HOST_WORKER_IDS)))
        probe = _probe_drive_host(DRIVE_HOST_WORKER_IDS[host])
        if probe === :alive
            DRIVE_HOST_LAST_SEEN[host] = now
            push!(rows, DriveHostStatus(host, :alive, now))
        else
            push!(rows, DriveHostStatus(host, :left, _last_seen_for(host)))
        end
    end
    isempty(rows) || _write_kit_hosts_status_file(rows, output_dir, log_dir)
    return nothing
end

function _mark_drive_hosts_collect_pending!(
        output_dir::AbstractString,
        log_dir::Union{Nothing, AbstractString};
        now::Float64 = time(),
    )
    rows = DriveHostStatus[]
    for host in sort!(collect(keys(DRIVE_HOST_WORKER_IDS)))
        probe = _probe_drive_host(DRIVE_HOST_WORKER_IDS[host])
        if probe === :alive
            DRIVE_HOST_LAST_SEEN[host] = now
            push!(rows, DriveHostStatus(host, :collect_pending, now))
        else
            push!(rows, DriveHostStatus(host, :left, _last_seen_for(host)))
        end
    end
    isempty(rows) || _write_kit_hosts_status_file(rows, output_dir, log_dir)
    return nothing
end

function _stop_drive_host_status_monitor!()
    DRIVE_HOST_STATUS_STOP[] = true
    t = DRIVE_HOST_STATUS_TASK[]
    DRIVE_HOST_STATUS_TASK[] = nothing
    if t !== nothing && !istaskdone(t)
        timedwait(() -> istaskdone(t), 2.0)
    end
    return nothing
end

function _start_drive_host_status_monitor!(
        output_dir::AbstractString,
        log_dir::Union{Nothing, AbstractString},
    )
    isempty(DRIVE_HOST_WORKER_IDS) && return nothing
    _require_drive_host_status_idle!()
    _stop_drive_host_status_monitor!()
    DRIVE_HOST_STATUS_STOP[] = false
    interval = _heartbeat_config().interval
    _refresh_drive_host_status_file!(output_dir, log_dir)
    DRIVE_HOST_STATUS_TASK[] = @async begin
        shield_sigint() do
            while !DRIVE_HOST_STATUS_STOP[]
                _ignore_interrupt() do
                    t0 = time()
                    while !DRIVE_HOST_STATUS_STOP[] && (time() - t0) < interval
                        sleep(0.2)
                    end
                    DRIVE_HOST_STATUS_STOP[] && return
                    try
                        _refresh_drive_host_status_file!(output_dir, log_dir)
                    catch
                    end
                    return nothing
                end
            end
        end
    end
    return nothing
end

function _read_kit_text_file(output_dir::AbstractString, name::AbstractString)::Union{Nothing, String}
    path = joinpath(String(output_dir), name)
    isfile(path) || return nothing
    s = try
        strip(read(path, String))
    catch
        return nothing
    end
    return isempty(s) ? nothing : s
end

function _parse_kit_pid_text(raw::AbstractString)
    s = strip(String(raw))
    isempty(s) && return nothing
    lines = split(s, '\n')
    pid = tryparse(Int, strip(String(lines[1])))
    pid === nothing && return nothing
    start = nothing
    if length(lines) >= 2
        st = strip(String(lines[2]))
        !isempty(st) && (start = st)
    end
    return (pid = Int(pid), start = start)
end

function _read_kit_pid_record(output_dir::AbstractString)
    raw = _read_kit_text_file(output_dir, "kit.pid")
    raw === nothing && return nothing
    return _parse_kit_pid_text(raw)
end

"""
    kit_pid_file_running(output_dir) -> Bool

Whether `kit.pid` names a still-running child of this run. Requires
`DistSSHRun.kit_pid_alive` and, when a start key is in the file, a match with
`kit_process_start_key`. A leftover after SIGKILL whose pid was reused
is false. One-line (pid-only) files keep the old probe. Missing file is false.
"""
function kit_pid_file_running(output_dir::AbstractString)::Bool
    rec = _read_kit_pid_record(output_dir)
    rec === nothing && return false
    kit_pid_alive(rec.pid) || return false
    rec.start === nothing && return true
    cur = kit_process_start_key(rec.pid)
    cur === nothing && return false
    return cur == rec.start
end

"""Kit run directory recorded next to `kit.pid`, else this package's `run.toml` here."""
function _run_dir_for_stop(dir::AbstractString)::Union{Nothing, String}
    recorded = _read_kit_text_file(dir, "kit.run_dir")
    if recorded !== nothing
        s = strip(recorded)
        !isempty(s) && return canonical_local_path(s)
    end
    raw = read_kit_run_toml(dir)
    raw !== nothing && _kit_run_toml_owned(raw) && return canonical_local_path(dir)
    return nothing
end

function _read_kit_hosts(output_dir::AbstractString)::Vector{String}
    raw = _read_kit_text_file(output_dir, "kit.hosts")
    raw === nothing && return String[]
    return String[strip(line) for line in split(raw, '\n') if !isempty(strip(line))]
end

# Wall clock for tagged `pkill` ssh. Connect timeout plus margin.
# Not computed, and not taken from `interrupt_grace`.
const _REAP_SSH_PHASE_S = 15.0

function _pkill_host_reached(result::_SSHHostResult)::Bool
    code = _ssh_phase_exit_code(result)
    code === nothing && return false
    return code == 0 || code == 1
end

"""One `pkill` per host. Exit 1 is success. Failures are one warning, never a throw."""
function _reap_remote_hosts!(job_id::AbstractString, hosts::AbstractVector{<:AbstractString})
    seen = String[]
    known = Set{String}()
    for host in hosts
        h = String(host)
        h in known && continue
        push!(known, h)
        push!(seen, h)
    end
    isempty(seen) && return nothing
    remote = _remote_tagged_pkill_sh(job_id)
    pairs = Pair{String, String}[host => remote for host in seen]
    results = try
        _run_ssh_hosts!(pairs, _REAP_SSH_PHASE_S)
    catch
        @warn "Tagged worker pkill did not reach: $(join(seen, ", "))"
        return nothing
    end
    missed = String[]
    for result in results
        _pkill_host_reached(result) || push!(missed, result.host)
    end
    isempty(missed) || @warn "Tagged worker pkill did not reach: $(join(missed, ", "))"
    return nothing
end

function _reap_tagged_workers!(job_id::Union{Nothing, AbstractString}, hosts::AbstractVector{<:AbstractString})
    job_id === nothing && return nothing
    id = String(job_id)
    _pkill_local_tagged_workers!(id)
    _reap_remote_hosts!(id, hosts)
    return nothing
end

function _require_nonnegative(name::AbstractString, value::Real)
    value >= 0 || throw(ArgumentError("$name must be ≥ 0, got $value"))
    return nothing
end

function _send_signal(p::Base.Process, sig::Integer)::Bool
    kill(p, sig)
    return true
end
function _send_signal(pid::Integer, sig::Integer)::Bool
    return ccall(:kill, Cint, (Cint, Cint), Cint(pid), Cint(sig)) == 0
end

_target_alive(p::Base.Process)::Bool = process_running(p)
_target_alive(pid::Integer)::Bool = kit_pid_alive(pid)

"""Send `sig` once if `target` is alive, then wait up to `wait_s` seconds.

Do not retry. A second signal is a separate force, not part of this wait.
`true` when this call delivered the signal.
"""
function _signal_and_wait!(
        target::Union{Base.Process, Integer},
        sig::Integer,
        wait_s::Real,
    )::Bool
    _target_alive(target) || return false
    sent = try
        _send_signal(target, sig)
    catch
        false
    end
    sent || return false
    t0 = time()
    while _target_alive(target) && (time() - t0) < Float64(wait_s)
        sleep(0.05)
    end
    return true
end

# Seconds to wait after SIGKILL. Part of the cancel budget, not a keyword.
const _SIGNAL_KILL_WAIT_S = 1.0

# Fixed default for `interrupt_grace`. Not computed at runtime.
# It covers SSH connect, `_INTERRUPT_SETTLE_S`, `_HEARTBEAT_STOP_S`,
# and `_RMPROCS_WAITFOR_S`, plus margin for a slow disk. A unit test
# checks that this constant still does.
const _INTERRUPT_GRACE_DEFAULT_S = 30.0

const _SIGINT_GRACE_ENV = "DISTSSH_WAIT_SIGINT_GRACE"

function _require_interrupt_grace(name::AbstractString, value::Real)
    if isfinite(value) && value >= 0
        return nothing
    end
    throw(ArgumentError("$name must be a finite number ≥ 0, got $value"))
end

"""
Keyword, else `DISTSSH_WAIT_SIGINT_GRACE` in this process, else 30 seconds.

The variable is read here, in the process calling `terminate!` or `cancel`,
not on the driver host. `0` is kept. A negative value, `NaN`, or `Inf` errors.
"""
function _resolve_interrupt_grace(explicit::Union{Nothing, Real})::Float64
    if explicit !== nothing
        _require_interrupt_grace("interrupt_grace", explicit)
        return Float64(explicit)
    end
    raw = strip(get(ENV, _SIGINT_GRACE_ENV, ""))
    if !isempty(raw)
        parsed = tryparse(Float64, raw)
        if parsed === nothing || !isfinite(parsed) || parsed < 0
            throw(ArgumentError("$_SIGINT_GRACE_ENV must be a finite number ≥ 0, got $(repr(raw))"))
        end
    end
    return DistSSHBase.wait_seconds(:sigint_grace, _INTERRUPT_GRACE_DEFAULT_S)
end

"""
SIGINT once, then SIGTERM, then SIGKILL.

`interrupt_grace == 0` does not send SIGINT. `grace == 0` still sends
SIGTERM and does not wait, which is what `terminate!` did before
`interrupt_grace` existed. SIGKILL is sent only when the process is still
alive, then this waits up to one second.

Returns the [`KitRunResult`](@ref) `stop` value, or `nothing` when `target`
was already gone (no signal sent). `:within_grace` / `:sigterm` /
`:sigkill` / `:no_sigint`.
"""
function _signal_ladder!(
        target::Union{Base.Process, Integer};
        interrupt_grace::Real,
        grace::Real,
    )::Union{Nothing, Symbol}
    if target isa Integer
        target <= 0 && return nothing
        Sys.isunix() || return nothing
    end
    _target_alive(target) || return nothing
    if interrupt_grace > 0
        sent_int = _signal_and_wait!(target, Base.SIGINT, interrupt_grace)
        if !_target_alive(target)
            return sent_int ? :within_grace : nothing
        end
    end
    sent_term = _signal_and_wait!(target, Base.SIGTERM, grace)
    if !_target_alive(target)
        sent_term || return interrupt_grace > 0 ? :within_grace : nothing
        return interrupt_grace > 0 ? :sigterm : :no_sigint
    end
    sent_kill = _signal_and_wait!(target, Base.SIGKILL, _SIGNAL_KILL_WAIT_S)
    sent_kill || return interrupt_grace > 0 ? :sigterm : :no_sigint
    return interrupt_grace > 0 ? :sigkill : :no_sigint
end

function _signal_and_wait_pid!(pid::Integer, grace::Real; interrupt_grace::Real = 0)::Union{Nothing, Symbol}
    return _signal_ladder!(pid; interrupt_grace = interrupt_grace, grace = grace)
end

"""Remove `kit.pid` in the same dirs as [`_write_kit_pid_file`](@ref), only if it still names `pid`."""
function _remove_kit_pid_file(
        pid::Integer,
        output_dir::Union{Nothing, AbstractString},
        log_dir::Union{Nothing, AbstractString};
        run_dir::Union{Nothing, AbstractString} = kit_run_dir(),
    )
    dirs = _kit_sidecar_dirs(output_dir, log_dir; run_dir = run_dir)
    isempty(dirs) && return nothing
    want = Int(pid)
    for d in dirs
        path = joinpath(d, "kit.pid")
        try
            rec = _parse_kit_pid_text(read(path, String))
            if rec !== nothing && rec.pid == want
                rm(path; force = true)
            end
        catch
            # best-effort only
        end
    end
    return nothing
end

"""Best-effort `kit.result` TOML next to `kit.pid`. Never throws."""
function _write_kit_result_file(
        result::KitRunResult;
        run_dir::Union{Nothing, AbstractString} = kit_run_dir(),
    )
    dirs = _kit_sidecar_dirs(result.output_dir, result.log_dir; run_dir = run_dir)
    isempty(dirs) && return nothing
    data = Dict{String, Any}(
        "ok" => result.ok,
        "kind" => String(result.kind),
        "exit_code" => result.exit_code,
    )
    result.output_dir !== nothing && (data["output_dir"] = String(result.output_dir))
    result.failed_step !== nothing && (data["failed_step"] = result.failed_step)
    result.log_dir !== nothing && (data["log_dir"] = result.log_dir)
    if !isempty(result.hosts)
        rows = Vector{Dict{String, Any}}(undef, length(result.hosts))
        for i in eachindex(result.hosts)
            h = result.hosts[i]
            row = Dict{String, Any}("host" => h.host, "ok" => h.ok)
            h.error !== nothing && (row["error"] = h.error)
            rows[i] = row
        end
        data["hosts"] = rows
    end
    if !isempty(result.tokens)
        data["tokens"] = result.tokens
    end
    result.stop !== nothing && (data["stop"] = String(result.stop))
    rd = result.run_dir === nothing ? run_dir : result.run_dir
    rd !== nothing && (data["run_dir"] = String(rd))
    for d in dirs
        try
            mkpath(d)
            dest = joinpath(d, "kit.result")
            tmp = dest * ".tmp"
            open(tmp, "w") do io
                TOML.print(io, data)
            end
            mv(tmp, dest; force = true)
        catch
            # best-effort only
        end
    end
    return nothing
end

"""
    kit_result_from_dir(output_dir) -> Union{Nothing,KitRunResult}

Read `output_dir/kit.result` written by a finished `go` / `ride` / `drive` child.
`nothing` when the file is missing or unreadable (still running, or a hard death).
"""
function kit_result_from_dir(output_dir::AbstractString)::Union{Nothing, KitRunResult}
    path = joinpath(canonical_local_path(output_dir), "kit.result")
    isfile(path) || return nothing
    try
        raw = TOML.parsefile(path)
        ok = raw["ok"]
        ok isa Bool || return nothing
        kind_s = raw["kind"]
        kind_s isa AbstractString || return nothing
        ks = String(kind_s)
        (ks == "go" || ks == "ride" || ks == "drive" || ks == "pipeline") || return nothing
        kind = Symbol(ks)
        code = raw["exit_code"]
        code isa Integer || return nothing
        od = get(raw, "output_dir", nothing)
        od_s = od isa AbstractString ? String(od) : nothing
        ld = get(raw, "log_dir", nothing)
        ld_s = ld isa AbstractString ? String(ld) : nothing
        fs = get(raw, "failed_step", nothing)
        fs_s = fs isa AbstractString ? String(fs) : nothing
        hosts = _kit_result_hosts_from_toml(get(raw, "hosts", nothing))
        tok_raw = get(raw, "tokens", nothing)
        tokens = String[]
        if tok_raw isa AbstractVector
            for t in tok_raw
                t isa AbstractString && push!(tokens, String(t))
            end
        end
        stop = _kit_stop_symbol(get(raw, "stop", nothing))
        rd = get(raw, "run_dir", nothing)
        rd_s = rd isa AbstractString ? String(rd) : nothing
        return KitRunResult(
            ok, kind, od_s, ld_s, fs_s, Int(code), hosts, tokens, stop;
            run_dir = rd_s,
        )
    catch
        return nothing
    end
end

function _kit_result_from_process(kp::KitProcess)::Union{Nothing, KitRunResult}
    for d in (kp.run_dir, kp.output_dir, kp.log_dir)
        d === nothing && continue
        recovered = kit_result_from_dir(d)
        recovered !== nothing && return recovered
    end
    return nothing
end

function _kit_result_hosts_from_toml(raw)::Vector{HostRunResult}
    raw isa AbstractVector || return HostRunResult[]
    out = HostRunResult[]
    for item in raw
        item isa AbstractDict || continue
        host = get(item, "host", nothing)
        host isa AbstractString || continue
        ok = get(item, "ok", nothing)
        ok isa Bool || continue
        err = get(item, "error", nothing)
        err_s = err isa AbstractString ? String(err) : nothing
        push!(out, HostRunResult(String(host), ok, err_s))
    end
    return out
end

"""
    drive_host_status(output_dir) -> Vector{DriveHostStatus}
    drive_host_status(kp::KitProcess) -> Vector{DriveHostStatus}

Live per-host membership for a running (or recently collecting) `drive`
or `ride`. Reads `kit.hosts.status`. Empty when the file is missing (too
early, a `go` run, or a hard death before join). This is not
[`DriveResult`](@ref) `hosts` (post-run collect); that vector is stored in
`kit.result` as `hosts`.
"""
function drive_host_status(output_dir::AbstractString)::Vector{DriveHostStatus}
    path = joinpath(canonical_local_path(output_dir), "kit.hosts.status")
    isfile(path) || return DriveHostStatus[]
    try
        raw = TOML.parsefile(path)
        rows = get(raw, "hosts", nothing)
        rows isa AbstractVector || return DriveHostStatus[]
        out = DriveHostStatus[]
        for item in rows
            item isa AbstractDict || continue
            host = get(item, "host", nothing)
            host isa AbstractString || continue
            st = get(item, "state", nothing)
            st isa AbstractString || continue
            state = Symbol(String(st))
            (
                state === :joined || state === :alive || state === :left ||
                    state === :collect_pending
            ) || continue
            ls = get(item, "last_seen", nothing)
            last = ls isa Real ? Float64(ls) : nothing
            push!(out, DriveHostStatus(String(host), state, last))
        end
        return out
    catch
        return DriveHostStatus[]
    end
end

function drive_host_status(kp::KitProcess)::Vector{DriveHostStatus}
    for d in (kp.run_dir, kp.output_dir, kp.log_dir)
        d === nothing && continue
        rows = drive_host_status(d)
        isempty(rows) || return rows
    end
    return DriveHostStatus[]
end

"""
    allocate_output_dir(kind, script; project=pwd(), job_id=nothing) -> String

Create a unique output directory for a later detached [`execute!`](@ref)
and return its path. `kind` is `:go`, `:drive`, or `:ride` (the same values as
`execute!`). The directory is created; pass it as `output_dir=`.

Layout is `{script dir}/.distsshkit/<kind>/<script-stem>_<UTC-stamp>/`. When
`job_id` is set it is appended after the stamp (same charset as
[`execute!`](@ref) `job_id`). The leaf is created with exclusive `mkdir`;
if it already exists (same-second collision), a nanosecond suffix is
retried so two allocations do not share a directory.

This matches omitted in-process defaults for go, ride, and drive:
`{script}/.distssh/<kind>/<stem>_<UTC>/`. Drive still honors
`output_dir` / `--output-dir` and a driver's `init_output_dir!`
(`DISTRIBUTED_OUTPUT_DIR`) when those are set. Detached `execute!(:drive)`
does not pin `--output-dir` unless `output_dir=` or inherited
`DISTRIBUTED_OUTPUT_DIR` is set.
"""
function allocate_output_dir(
        kind::Symbol,
        script::AbstractString;
        project::AbstractString = pwd(),
        job_id::Union{Nothing, AbstractString} = nothing,
    )::String
    _require_execute_kind!(kind)
    proj = canonical_local_path(project)
    isdir(proj) || throw(ArgumentError("allocate_output_dir: project is not a directory: $proj"))
    stem = splitext(basename(String(script)))[1]
    isempty(stem) && throw(ArgumentError("allocate_output_dir: empty script basename"))
    stamp = Dates.format(Dates.now(Dates.UTC), dateformat"yyyymmddTHHMMSS") * "Z"
    leaf = if job_id !== nothing && !isempty(strip(String(job_id)))
        "$(stem)_$(stamp)_$(_parse_kit_job_id(String(job_id)))"
    else
        "$(stem)_$(stamp)"
    end
    raw = String(script)
    script_path = isabspath(raw) ? raw : joinpath(proj, raw)
    dir = joinpath(kit_dir_beside_script(dirname(canonical_local_path(script_path)), kind), leaf)
    return _mkdir_unique!(dir)
end

"""Set `DISTRIBUTED_OUTPUT_DIR` for a drive run and return it.

If the env is already non-blank (`--output-dir`, `output_dir=`, or
`init_output_dir!`), canonicalize and keep it. Otherwise allocate a unique
`{script}/.distssh/drive/<stem>_<UTC>/` leaf.
"""
function _ensure_drive_output_env!(
        script_path::AbstractString;
        project::AbstractString = pwd(),
    )::String
    existing = strip(get(ENV, "DISTRIBUTED_OUTPUT_DIR", ""))
    if !isempty(existing)
        dir = canonical_local_path(existing)
        mkpath(dir)
        ENV["DISTRIBUTED_OUTPUT_DIR"] = dir
        return dir
    end
    dir = allocate_output_dir(:drive, script_path; project = project)
    ENV["DISTRIBUTED_OUTPUT_DIR"] = dir
    return dir
end

function _execute_detached_dirs(
        kind::Symbol,
        project::AbstractString,
        script_path::AbstractString,
        output_dir::Union{Nothing, AbstractString},
        log_dir::Union{Nothing, AbstractString},
        enable_log,
        run_dir::AbstractString,
    )::Tuple{Union{Nothing, String}, Union{Nothing, String}}
    resolved_output = if output_dir !== nothing
        canonical_local_path(output_dir)
    elseif kind === :go
        _go_batch_output_dir(project, script_path)
    elseif kind === :ride
        _ride_batch_dir(script_path, nothing; project = project)
    else
        inherited = strip(get(ENV, "DISTRIBUTED_OUTPUT_DIR", ""))
        if !isempty(inherited)
            d = canonical_local_path(inherited)
            mkpath(d)
            d
        else
            nothing
        end
    end
    resolved_log = if kind === :go || kind === :ride || enable_log === false
        nothing
    elseif log_dir !== nothing
        canonical_local_path(String(log_dir))
    else
        canonical_local_path(run_dir)
    end
    return resolved_output, resolved_log
end

function _execute_detached_argv(
        kind::Symbol,
        script_path::AbstractString,
        tokens::AbstractVector{<:AbstractString},
        args::AbstractVector{<:AbstractString};
        output_dir::Union{Nothing, AbstractString},
        log_dir::Union{Nothing, AbstractString},
        sync::Union{Symbol, Bool, Nothing},
        julia::Union{Nothing, AbstractString},
        quiet::Bool,
        verbosity,
        hosts_file,
        enable_log,
        package,
        require_all_hosts,
        skip_hash_check,
        workers = nothing,
        repeat = nothing,
        worker_include::Bool = false,
        spi_check::Bool = false,
        allow_mismatch = Symbol[],
        allow_external_symlinks::Bool = false,
        run_id::Union{Nothing, AbstractString} = nothing,
        remote::Union{Nothing, AbstractString} = nothing,
    )::Vector{String}
    argv = String[String(kind)]
    push!(argv, "-y")
    append!(argv, allow_mismatch_argv(allow_mismatch))
    if verbosity === nothing
        quiet && push!(argv, "-q")
    elseif verbosity === :quiet
        push!(argv, "-q")
    elseif verbosity === :progress
        push!(argv, "--progress")
    elseif verbosity === :verbose
        push!(argv, "--verbose")
    else
        throw(ArgumentError("verbosity must be :quiet, :progress, or :verbose, got $(repr(verbosity))"))
    end
    output_dir !== nothing && push!(argv, "--output-dir", String(output_dir))
    _reject_run_transfer_kw!("execute!", sync; surface = :api)
    allow_external_symlinks &&
        _reject_run_transfer_cli!(String(kind), "--allow-external-symlinks")
    if run_id !== nothing
        push!(argv, "--run-id", validate_run_id(run_id))
    end
    if remote !== nothing && !isempty(strip(String(remote)))
        push!(argv, DEPLOY_ROOT_FLAG, String(strip(String(remote))))
    end
    if !_julia_spec_is_auto(julia)
        push!(argv, "--julia", String(strip(String(julia))))
    end
    if hosts_file !== nothing && !isempty(strip(String(hosts_file)))
        push!(argv, "--hosts-file", canonical_local_path(String(hosts_file)))
    end
    if kind === :drive
        enable_log === false && push!(argv, "--no-log")
        if log_dir !== nothing
            push!(argv, "--log-dir", String(log_dir))
        end
        if package !== nothing && !isempty(strip(String(package)))
            push!(argv, "--package", String(package))
        end
        require_all_hosts isa Bool || throw(
            ArgumentError(
                "require_all_hosts must be a Bool, got $(repr(require_all_hosts))",
            )
        )
        if require_all_hosts
            push!(argv, "--require-all-hosts")
        else
            push!(argv, "--best-effort")
        end
        skip_hash_check === false && push!(argv, "--require-git")
        if workers !== nothing
            push!(argv, "--workers", string(Int(workers)))
        end
        worker_include && push!(argv, "--worker-include")
    elseif kind === :ride
        if spi_check
            push!(argv, "--spi-check")
        else
            push!(argv, "--no-spi-check")
        end
    else
        if repeat !== nothing
            push!(argv, "--repeat", string(Int(repeat)))
        end
    end
    for tok in tokens
        push!(argv, String(tok))
    end
    push!(argv, String(script_path))
    for a in args
        push!(argv, String(a))
    end
    return argv
end

"""Log how many names were dropped. The name list is debug-only. Never log values."""
function _log_detached_dropped!(dropped::AbstractVector{<:AbstractString})
    isempty(dropped) && return nothing
    n = length(dropped)
    @info "detached execute!: dropped $n environment variables not on the allowlist. Names are in detached_launch, run.toml [launch], and the debug log (JULIA_DEBUG=DistSSHRun)."
    @debug "detached execute!: dropped environment variable names" names = join(dropped, ", ")
    return nothing
end

function _reject_inprocess_launch!(dir, threads, env_allow, env)
    dir === nothing || throw(
        ArgumentError(
            "execute!(...; detached=false) does not accept dir",
        )
    )
    _detached_threads_is_default(threads) || throw(
        ArgumentError(
            "execute!(...; detached=false) does not accept threads",
        )
    )
    env_allow === nothing || throw(
        ArgumentError(
            "execute!(...; detached=false) does not accept env_allow",
        )
    )
    env === nothing || throw(
        ArgumentError(
            "execute!(...; detached=false) does not accept env",
        )
    )
    return nothing
end

function _detached_threads_is_default(threads)::Bool
    threads isa Bool && return false
    threads isa Integer || return false
    return Int(threads) == 1
end

"""`N` or `N,M` from resolved counts. `ni == 0` omits the interactive pool."""
function _detached_threads_from_counts(n::Integer, ni::Integer)::String
    n isa Bool && throw(ArgumentError("threads must be >= 1, got $(repr(n))"))
    ni isa Bool && throw(ArgumentError("interactive threads must be >= 0, got $(repr(ni))"))
    nn = Int(n)
    nni = Int(ni)
    nn >= 1 || throw(ArgumentError("threads must be >= 1, got $nn"))
    nni >= 0 || throw(ArgumentError("interactive threads must be >= 0, got $nni"))
    return nni > 0 ? "$(nn),$(nni)" : string(nn)
end

function _detached_thread_flag(threads)::String
    threads isa Bool && throw(
        ArgumentError(
            "threads must be an integer, a thread spec, :inherit, or :unset, got $(repr(threads))",
        )
    )
    if threads isa Integer
        return _detached_threads_from_counts(threads, 0)
    end
    if threads isa Symbol
        threads === :inherit && return _launch_thread_spec()
        threads === :unset && return "unset"
        throw(
            ArgumentError(
                "threads must be an integer, a thread spec, :inherit, or :unset, got $(repr(threads))",
            )
        )
    end
    threads isa AbstractString || throw(
        ArgumentError(
            "threads must be an integer, a thread spec, :inherit, or :unset, got $(repr(threads))",
        )
    )
    s = strip(String(threads))
    s == "auto" && return "auto"
    if occursin(r"^[1-9][0-9]*$", s)
        return s
    end
    m = match(r"^([1-9][0-9]*),([0-9]+)$", s)
    m === nothing && throw(
        ArgumentError(
            "threads must be an integer, auto, N,M, :inherit, or :unset, got $(repr(threads))",
        )
    )
    n = parse(Int, String(something(m.captures[1], "")))
    ni = parse(Int, String(something(m.captures[2], "")))
    ni >= 0 || throw(ArgumentError("interactive threads must be >= 0, got $ni"))
    return "$(n),$(ni)"
end

function _detached_launch_dir(dir, project::AbstractString)::String
    raw = dir === nothing ? String(project) : String(dir)
    d = canonical_local_path(raw)
    isdir(d) || throw(ArgumentError("detached execute! dir is not a directory: $(d)"))
    # `canonical_local_path` is `abspath` and does not resolve symlinks.
    # macOS `getcwd` turns `/var` into `/private/var`, so the child `pwd()`
    # would not match the directory we passed. Pass the physical path.
    return canonical_local_path(realpath(d))
end

function _detached_env_name_ok(name::AbstractString)
    s = String(name)
    (isempty(s) || occursin('=', s) || occursin('\0', s)) && throw(
        ArgumentError(
            "detached execute! env name is invalid: $(repr(s))",
        )
    )
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", s) || throw(
        ArgumentError(
            "detached execute! env name is invalid: $(repr(s))",
        )
    )
    return s
end

_detached_cookie_name(name::AbstractString)::Bool = occursin("COOKIE", uppercase(String(name)))

function _detached_sensitive_name(name::AbstractString)::Bool
    s = String(name)
    for part in _EXECUTE_DETACHED_DENY_PARTS
        occursin(part, s) && return true
    end
    return false
end

function _detached_prefix_keep(name::AbstractString)::Bool
    s = String(name)
    return startswith(s, "LC_") || startswith(s, "DISTSSH_") || startswith(s, "DISTRIBUTED_")
end

function _detached_proxy_userinfo(name::AbstractString, value::AbstractString)::Bool
    String(name) in _EXECUTE_DETACHED_PROXY_NAMES || return false
    return occursin(_EXECUTE_DETACHED_PROXY_USERINFO, String(value))
end

function _detached_reject_explicit_name!(name::AbstractString; threads_unset::Bool)
    s = _detached_env_name_ok(name)
    if s in _EXECUTE_DETACHED_HARD_DROP
        throw(ArgumentError("detached execute! cannot pass $(s)"))
    end
    if s == "JULIA_NUM_THREADS" && !threads_unset
        throw(
            ArgumentError(
                "detached execute! cannot pass JULIA_NUM_THREADS unless threads=:unset",
            )
        )
    end
    return s
end

function _detached_normalize_allow(env_allow, threads_unset::Bool)
    env_allow === nothing && return String[]
    env_allow === :all && return :all
    env_allow isa AbstractVector || throw(
        ArgumentError(
            "env_allow must be nothing, a list of names, or :all, got $(repr(env_allow))",
        )
    )
    out = String[]
    for item in env_allow
        item isa AbstractString || throw(
            ArgumentError(
                "env_allow names must be strings, got $(repr(item))",
            )
        )
        push!(out, _detached_reject_explicit_name!(item; threads_unset = threads_unset))
    end
    return out
end

function _detached_normalize_sets(env, threads_unset::Bool)::Dict{String, String}
    env === nothing && return Dict{String, String}()
    env isa AbstractDict || throw(
        ArgumentError(
            "env must be nothing or a Dict of strings, got $(repr(env))",
        )
    )
    out = Dict{String, String}()
    for (k, v) in env
        k isa AbstractString || throw(
            ArgumentError(
                "env names must be strings, got $(repr(k))",
            )
        )
        v isa AbstractString || throw(
            ArgumentError(
                "env values must be strings, got $(repr(v))",
            )
        )
        name = _detached_reject_explicit_name!(k; threads_unset = threads_unset)
        out[name] = String(v)
    end
    return out
end

"""Child environment, dropped parent names, and sensitive explicit names.

`parent` is not modified. Thread and BLAS variables stay out unless
`threads` is `:unset`. The five BLAS variables are then set to
`DISTSSH_BLAS_THREADS` or `"1"`. `OPENBLAS_DEFAULT_NUM_THREADS` is not
set. Bookkeeping `DISTSSH_LAUNCH_*` and `DISTSSH_SKIP_GLOBAL_WORKER_PKILL`
are written on the child only.
"""
function _detached_child_env(
        parent::AbstractDict,
        extra::AbstractDict{<:AbstractString, <:AbstractString};
        threads,
        env_allow,
        env,
        launch_dir::AbstractString,
        source::Union{Nothing, AbstractDict},
    )
    flag = _detached_thread_flag(threads)
    unset = flag == "unset"
    allow = _detached_normalize_allow(env_allow, unset)
    sets = _detached_normalize_sets(env, unset)
    allow_set = allow === :all ? Set{String}() : Set{String}(allow)
    child = Dict{String, String}()
    sensitive = String[]
    baseline = Set{String}(_EXECUTE_DETACHED_BASELINE)
    hard = Set{String}(_EXECUTE_DETACHED_HARD_DROP)
    thread_vars = Set{String}(_EXECUTE_DETACHED_THREAD_VARS)

    function take_parent!(name::AbstractString, value::AbstractString; explicit_name::Bool)
        isempty(value) && return nothing
        _detached_cookie_name(name) && return nothing
        name in hard && return nothing
        !unset && name in thread_vars && return nothing
        if !explicit_name && _detached_proxy_userinfo(name, value)
            return nothing
        end
        if _detached_sensitive_name(name) && !explicit_name
            return nothing
        end
        child[String(name)] = String(value)
        if explicit_name && _detached_sensitive_name(name)
            push!(sensitive, String(name))
        end
        return nothing
    end

    for (k, v) in parent
        name = String(k)
        value = v isa AbstractString ? String(v) : string(v)
        isempty(value) && continue
        explicit_name = name in allow_set
        take = allow === :all || explicit_name || name in baseline || _detached_prefix_keep(name)
        take || continue
        take_parent!(name, value; explicit_name = explicit_name)
    end

    for (name, value) in sets
        if isempty(value)
            delete!(child, name)
            continue
        end
        if _detached_cookie_name(name) || name in hard
            continue
        end
        if !unset && name in thread_vars
            continue
        end
        child[name] = value
        _detached_sensitive_name(name) && push!(sensitive, name)
    end

    for (k, v) in extra
        child[String(k)] = String(v)
    end
    _drop_unspecified_source_env!(child, source, extra)

    if !unset
        for name in thread_vars
            delete!(child, name)
        end
        blas = strip(get(child, "DISTSSH_BLAS_THREADS", ""))
        blas_value = isempty(blas) ? "1" : blas
        for name in _EXECUTE_DETACHED_BLAS_SET
            child[name] = blas_value
        end
    end

    dropped = String[]
    for (k, v) in parent
        name = String(k)
        value = v isa AbstractString ? String(v) : string(v)
        isempty(value) && continue
        haskey(child, name) || push!(dropped, name)
    end
    for name in keys(sets)
        _detached_cookie_name(name) || continue
        name in dropped || push!(dropped, name)
    end
    sort!(dropped)
    unique!(dropped)
    sort!(sensitive)
    unique!(sensitive)

    child["DISTSSH_SKIP_GLOBAL_WORKER_PKILL"] = "1"
    child["DISTSSH_LAUNCH_THREADS"] = flag
    child["DISTSSH_LAUNCH_DIR"] = String(launch_dir)
    child["DISTSSH_LAUNCH_DROPPED"] = join(dropped, ",")
    return (
        env = child,
        dropped = dropped,
        sensitive = sensitive,
        threads = flag,
    )
end

function _result_with_stop(result::KitRunResult, stop::Union{Nothing, Symbol})::KitRunResult
    parsed = _kit_stop_symbol(stop)
    parsed === nothing && return result
    result.stop === parsed && return result
    return KitRunResult(
        result.ok,
        result.kind,
        result.output_dir,
        result.log_dir,
        result.failed_step,
        result.exit_code,
        result.hosts,
        result.tokens,
        parsed;
        run_dir = result.run_dir,
    )
end

"""Write `stop` onto `result` and `kit.result`. Stamp `run.toml` only in `run_dir`."""
function _persist_stop(
        result::KitRunResult,
        stop::Union{Nothing, Symbol};
        run_dir::Union{Nothing, AbstractString} = nothing,
    )::KitRunResult
    stamped = _result_with_stop(result, stop)
    stamped.stop === nothing && return stamped
    _write_kit_result_file(stamped; run_dir = run_dir)
    if run_dir !== nothing && !isempty(strip(String(run_dir)))
        _stamp_run_toml_stop!(run_dir, stamped.stop)
    end
    return stamped
end

"""
    terminate!(kp::KitProcess; grace=10, interrupt_grace=nothing) -> KitRunResult

Stop a detached run. Omit `interrupt_grace` and the wait is 30 seconds, or
`DISTSSH_WAIT_SIGINT_GRACE` when that variable is set in this process.
The driver host does not read it. An explicit `interrupt_grace` keyword
wins, including `0`, which sends no SIGINT. A negative value or `NaN` is
an error. The 30 second default is a constant, chosen from the internal
stop budgets, not computed when [`terminate!`](@ref) runs.

A positive value sends SIGINT once and waits that many seconds. There is
no retry. A `drive` child runs its Ctrl-C path: one `kill -INT` per SSH
host, aimed at the worker julia pid (`WorkerConfig.ospid`, the worker's
`getpid()`), then a fixed 3 second settle, then `rmprocs`. That ssh is
bounded by the SSH connect timeout and uses `ServerAliveInterval=5` and
`ServerAliveCountMax=1`. A write during the settle window is best-effort
and should be small. Checkpoint large state during the run, to a temporary
file, then rename it. A 1 GiB write in 0.4–0.7 seconds on one Mac mini is
a lower bound. On Julia 1.13 a second Ctrl-C forces the driver out of that
cleanup. On Julia 1.13, a driver waiting in `pmap` ignores SIGINT, so this
wait runs out and SIGTERM stops it. With the defaults that is 30 seconds
plus `grace` (10) plus one second after SIGKILL, about 41 seconds, and
then the tagged `pkill` below. A
process-group SIGINT, as from a terminal Ctrl-C, also misses that path on
Julia 1.13: the driver exits 1 and does not send `kill -INT`. Measured on
macOS. On Julia 1.14 the driver exits 130, but a worker can be removed
before it sees the interrupt.
A `go` or `ride` child is `julia -m` with
exit-on-sigint, so SIGINT runs `atexit` and does not enter `catch` or
`finally`. Then SIGTERM, wait up to `grace` seconds (`0` sends SIGTERM
and does not wait), then SIGKILL if the process is still alive. Then
`pkill` only processes tagged with this run's `job_id` (from `kit.job`),
never `julia.*--worker`. Without `job_id`, only the child is signaled.
That `pkill` is one SSH command per host, in parallel, deduplicated, with
its own 15 second bound (SSH connect plus margin). It does not spend
`interrupt_grace`. Worst case for those two stages is `interrupt_grace`
plus that bound. `pkill` exit 1 means nothing matched and is success.
Hosts that cannot be reached are named in one warning, and this still
returns. The remote pattern is `[d]istsshkit-job:…`, so `pkill -f` does
not match the `sh -c` line that contains the command.

The returned [`KitRunResult`](@ref) `stop` is that ladder outcome. The same
string is written to `kit.result`. When `run_dir` holds this package's
`run.toml` (`schema = 1`, `writer` starting with `DistSSHRun `), `stop` is
set there too. Artifact `output_dir` / `log_dir` are not rewritten.
"""
function terminate!(
        kp::KitProcess;
        grace::Real = 10,
        interrupt_grace::Union{Nothing, Real} = nothing,
    )::KitRunResult
    _require_nonnegative("grace", grace)
    seconds = _resolve_interrupt_grace(interrupt_grace)
    stop = _signal_ladder!(kp.process; interrupt_grace = seconds, grace = grace)
    sidecar = something(kp.run_dir, kp.output_dir)
    job_id = sidecar === nothing ? nothing : _read_kit_text_file(sidecar, "kit.job")
    hosts = sidecar === nothing ? String[] : _read_kit_hosts(sidecar)
    _reap_tagged_workers!(job_id, hosts)
    return _persist_stop(wait(kp), stop; run_dir = kp.run_dir)
end

"""
    terminate_run!(output_dir; grace=10, interrupt_grace=nothing, log_dir=nothing, kind=:go) -> KitRunResult

Like [`terminate!`](@ref) after losing [`KitProcess`](@ref): read `kit.pid` /
`kit.job` / `kit.hosts` under `output_dir`. `interrupt_grace` is the same
SIGINT stage, including the 30 second default and
`DISTSSH_WAIT_SIGINT_GRACE` in this process. `kind` is only used when
`kit.result` is missing. `stop` is the ladder outcome, including on that
synthetic result. `run.toml` is stamped in the kit run directory named by
`kit.run_dir` next to `kit.pid`, or in `output_dir` when that directory
already holds this package's `run.toml`.
"""
function terminate_run!(
        output_dir::AbstractString;
        grace::Real = 10,
        interrupt_grace::Union{Nothing, Real} = nothing,
        log_dir::Union{Nothing, AbstractString} = nothing,
        kind::Symbol = :go,
    )::KitRunResult
    _require_nonnegative("grace", grace)
    seconds = _resolve_interrupt_grace(interrupt_grace)
    _require_execute_kind!(kind)
    d = canonical_local_path(output_dir)
    rec = _read_kit_pid_record(d)
    stop = nothing
    if rec !== nothing && kit_pid_file_running(d)
        stop = _signal_and_wait_pid!(rec.pid, grace; interrupt_grace = seconds)
    end
    job_id = _read_kit_text_file(d, "kit.job")
    _reap_tagged_workers!(job_id, _read_kit_hosts(d))
    run_d = _run_dir_for_stop(d)
    recovered = kit_result_from_dir(d)
    if recovered === nothing && run_d !== nothing
        recovered = kit_result_from_dir(run_d)
    end
    result = recovered !== nothing ? recovered : KitRunResult(
            false,
            kind,
            d,
            log_dir === nothing ? nothing : canonical_local_path(String(log_dir)),
            "terminated",
            1;
            run_dir = run_d,
        )
    return _persist_stop(result, stop; run_dir = run_d)
end
