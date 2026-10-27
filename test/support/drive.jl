if !isdefined(Main, :_run_kit_drive)

    # Normalize a host project path for drive subprocesses.
    function _drive_host_root(path)::String
        return abspath(string(path))
    end

    # Prepend `-y` unless the flags already include `-y` / `--yes`.
    function _drive_yes_flags(drive_flags::Vector{String})::Vector{String}
        any(f -> f == "-y" || f == "--yes", drive_flags) && return drive_flags
        return vcat(["-y"], drive_flags)
    end

    # Child env for a host project: no init delay, project root set.
    function _drive_host_env(
            host_root;
            extra_env::Dict{String, String} = Dict{String, String}(),
        )
        return _child_julia_env(
            merge(
                Dict(
                    "DISTRIBUTED_INIT_DELAY_SEC" => "0",
                    "DISTRIBUTED_PROJECT_ROOT" => _drive_host_root(host_root),
                ),
                extra_env,
            ),
        )
    end

    # Kit `drive` CLI command. Does not start the process.
    function _kit_drive_cmd(;
            script::AbstractString,
            host_root,
            parent_workers::Int = 1,
            child_hosts::Vector{String} = String[],
            log_dir::Union{Nothing, String} = nothing,
            script_args::Vector{String} = String[],
            kit_root::AbstractString = _kit_root(),
            julia::AbstractString = _julia_exe(),
            drive_flags::Vector{String} = String[],
            extra_env::Dict{String, String} = Dict{String, String}(),
        )::Cmd
        script = String(script)
        host_root = _drive_host_root(host_root)
        kit_root = String(kit_root)
        julia = String(julia)
        log_flags = log_dir === nothing ? ["--no-log"] : ["--log-dir", log_dir]
        worker_tokens = String[]
        parent_workers > 0 && push!(worker_tokens, "parent:$(parent_workers)")
        append!(worker_tokens, child_hosts)
        isempty(worker_tokens) && error("_run_kit_drive: need parent_workers > 0 or child_hosts")
        cmd = _kit_cli_cmd(
            vcat(["drive"], _drive_yes_flags(drive_flags), worker_tokens, log_flags, [script], script_args);
            julia = julia,
            project = kit_root,
        )
        return setenv(cmd, _drive_host_env(host_root; extra_env))
    end

    # Run the kit `drive` CLI with a host `DISTRIBUTED_PROJECT_ROOT`.
    function _run_kit_drive(; kwargs...)
        return _run_subprocess(_kit_drive_cmd(; kwargs...))
    end

    # Run `drive --collect-missing|--collect-overwrite ROOT HOST...` as a child CLI.
    function _run_kit_drive_collect(;
            collect_root::AbstractString,
            hosts::Vector{String},
            overwrite::Bool = false,
            host_root,
            kit_root::AbstractString = _kit_root(),
            julia::AbstractString = _julia_exe(),
            extra_env::Dict{String, String} = Dict{String, String}(),
        )
        isempty(hosts) && error("_run_kit_drive_collect: need hosts")
        flag = overwrite ? "--collect-overwrite" : "--collect-missing"
        cmd = _kit_cli_cmd(
            vcat(["drive", "-y", "-q", flag, String(collect_root)], hosts);
            julia = String(julia),
            project = String(kit_root),
        )
        env = _child_julia_env(
            merge(
                Dict(
                    "DISTRIBUTED_PROJECT_ROOT" => _drive_host_root(host_root),
                ), extra_env
            )
        )
        return _run_subprocess(setenv(cmd, env))
    end

    # Host-app `drive`. A checkout with a manifest still runs `drive.jl`
    # (`--project` is the host). A checkout with no manifest uses
    # `julia -m DistSSHRun` and `--project=TEST_PROJECT`.
    function _host_drive_cmd(;
            script::AbstractString,
            host_project,
            parent_workers::Int = 2,
            log_dir::Union{Nothing, String} = nothing,
            kit_root::AbstractString = _kit_root(),
            julia::AbstractString = _julia_exe(),
        )::Cmd
        script = String(script)
        host_project = _drive_host_root(host_project)
        kit_root = String(kit_root)
        log_flags = log_dir === nothing ? String["--no-log"] : String["--log-dir", String(log_dir)]
        tokens = String["-y", "parent:$(parent_workers)"]
        append!(tokens, log_flags)
        push!(tokens, script)
        base = _julia_cmd_for(julia)
        cmd = if _checkout_manifest_file(kit_root) !== nothing
            drive = joinpath(kit_root, "src", "cli", "drive.jl")
            `$base --startup-file=no --project=$host_project $drive $tokens`
        else
            proj = _cli_m_project(kit_root)
            `$base --startup-file=no --project=$proj -m DistSSHRun drive $tokens`
        end
        # Same child env as `_kit_drive_cmd`: `@` + `@stdlib`, depot inherited,
        # `JULIA_PROJECT` removed. `addenv` would keep this process's load path.
        return setenv(cmd, _drive_host_env(host_project))
    end

    # Run a host-app `drive` and return `(process, output)`.
    function _run_host_drive(; kwargs...)
        return _run_subprocess(_host_drive_cmd(; kwargs...))
    end

    # Run a local drive subprocess with logging enabled; assert console + log contents.
    function _assert_drive_log_output(; cmd::Cmd, log_dir::String)
        proc, combined = _run_subprocess(cmd)

        _assert_proc_ok(proc, combined; label = "drive log smoke")
        @test occursin("DISTSSHKIT_RUNNER_SMOKE_OK nw=2", combined)
        @test occursin("Results:", combined)

        log_files = String[
            name for name in readdir(log_dir)
                if startswith(name, "drive_") && endswith(name, ".log")
        ]
        @test length(log_files) == 1
        log_content = read(joinpath(log_dir, only(log_files)), String)

        for needle in (
                "Subcommand args: drive",
                "Julia binary:",
                "Script:",
                "Workers:",
                "Running script...",
                "DISTSSHKIT_RUNNER_SMOKE_OK nw=2",
                "Results:",
            )
            @test occursin(needle, log_content)
        end

        return combined, log_content
    end

end
