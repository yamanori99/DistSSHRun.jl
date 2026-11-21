# Argument parsing for `go` (as-is complete jobs).

"""Print `go --help` (same chrome as `julia -m DistSSHKit go -h`)."""
function show_go_usage(; io::IO = stdout)
    print_help_chrome(cli_heading("go"); io = io)
    print_help_lines(
        io,
        "Standalone script. One full run per slot; slots start together.",
        "Remotes: setup ship-tree or setup git-clone, then setup instantiate.",
        "Then go --run-id ID (or last-ship.toml / git checkout).",
    )
    print_help_blank(io)
    print_help_section("Usage"; io = io)
    print_help_lines(
        io,
        "  $(cli_m_project()) go [slots...] SCRIPT.jl",
        "  go --head-slots 2 SCRIPT.jl",
        "  go --repeat 100 SCRIPT.jl",
        "  go --repeat 100 1*host1 2*host2 SCRIPT.jl",
        "  go --head-slots 1 2*host1 SCRIPT.jl",
    )
    print_help_blank(io)
    print_help_section("Slots"; io = io)
    print_help_lines(
        io,
        "  N*host              quote tokens; bare host = 1 slot (SSH)",
        "  $(KIT_HEAD_SLOTS_FLAG_HELP)",
        "  omit host count     error unless --repeat (then host is uncapped)",
        "  --repeat N          N independent runs; spread across listed hosts",
        "                       (`N*host` is a per-host cap; bare host is uncapped)",
        "  $(KIT_HOSTS_FLAG_HELP)",
        "  --hosts-file PATH   one token per line",
    )
    print_help_blank(io)
    print_help_section("Options"; io = io)
    print_help_lines(
        io,
        "  --deploy-root PATH  remote deployment root (location, not snapshot id).",
        "                      Omit for DISTRIBUTED_REMOTE_PROJECT_ROOT, else the",
        "                      ~/Parent/RepoName layout from the local env_dir.",
        "  --run-id ID       use runs/<ID>/src under the deploy root",
        "                      (after setup ship-tree + setup instantiate)",
        "  --julia PATH        remote Julia (ENV or auto)",
        generated_run_option_help(:go)...,
        "  Remote slots cd to the project root and pin the real julia binary.",
        "  --output-dir PATH   batch root; slots are PATH/<slot>/",
        "  $(KIT_QUIET_FLAG_HELP)",
        "  $(KIT_PROGRESS_FLAG_HELP)",
        "  $(KIT_VERBOSE_FLAG_HELP)",
        "  -y, --yes           skip confirmations",
        "  --version, -v       print version and exit",
        "  -h, --help          this help",
    )
    print_help_blank(io)
    print_help_lines(io, "  $(KIT_TIME_HELP)")
    print_help_blank(io)
    print_help_section("Output"; io = io)
    print_help_lines(
        io,
        "  {script}/.distssh/go/<stem>_<UTC>/<slot>/",
        "  DISTRIBUTED_OUTPUT_DIR → that slot dir",
        "  --output-dir is the batch root (not drive's result root)",
        "  a non-empty --output-dir is an error",
        "  slot pull-back uses Tar (remote mtimes and file modes are not kept)",
        "  modes are 0644, or 0755 if executable; remote Julia is --julia or auto-detect",
    )
    print_help_blank(io)
    print_help_section("Environment"; io = io)
    print_help_lines(
        io,
        "  $(KIT_HOSTS_ENV_HELP)",
        "  JULIA_DISTRIBUTED_EXE        default remote Julia",
        "  DISTSSH_QUIET / PROGRESS / VERBOSE / YES",
    )
    print_help_blank(io)
    return print_help_lines(
        io,
        "Details: docs (options.md, manual/go). Common errors: docs (common_errors.md).",
        "See also: setup, drive.",
    )
end

function _go_parse_repeat(raw::AbstractString)::Int
    n = tryparse(Int, strip(String(raw)))
    (n === nothing || n < 1) && throw(
        ArgumentError(
            "go --repeat must be an integer >= 1, got $(repr(raw))",
        )
    )
    return n
end

function _go_parsed(;
        help::Bool,
        show_version,
        cli_session,
        script_path,
        script_args,
        hosts,
        output_dir,
        julia,
        repeat,
        run_opts::RunOptionCliState = RunOptionCliState(),
        run_id = nothing,
        deploy_root = nothing,
    )
    base = (
        help = help,
        show_version = show_version,
        cli_session = cli_session,
        script_path = script_path,
        script_args = script_args,
        hosts = hosts,
        output_dir = output_dir,
        julia = julia,
        repeat = repeat,
        run_id = run_id,
        deploy_root = deploy_root,
    )
    return merge_run_option_cli!(base, run_opts)
end

"""Parse `go` CLI arguments (same shape as other kit CLI parsers)."""
function parse_go_args(
        args::AbstractVector{<:AbstractString};
        env::ProcessEnv = snapshot_process_env(),
    )
    args_vec = Vector{String}(String.(args))
    blob_path, _ = peel_job_blob_bootstrap(copy(args_vec))
    if blob_path !== nothing
        scrub_detached_placement_env!()
        env = snapshot_process_env()
        return go_parsed_from_detached_job_blob(
            read_detached_job_blob(blob_path);
            process_env = env,
        )
    end
    reject_mistaken_short_placement_flags!(args; command = :go)
    assert_go_argv_no_head_workers!(args)
    cli_session, rest = peel_shared_cli_flags(args; env = env)
    hosts = String[]
    host_tokens = String[]
    script_path = nothing
    script_args = String[]
    output_dir = nothing
    julia_exe = nothing
    run_opts = RunOptionCliState()
    run_id = nothing
    deploy_root = nothing
    repeat_n::Union{Nothing, Int} = nothing
    options_done = false
    c = CliCursor(collect(String, rest))
    while !cli_at_end(c)
        arg = cli_current(c)::String
        if options_done
            if endswith(arg, ".jl")
                script_path = arg
                cli_consume!(c)
                while !cli_at_end(c)
                    push!(script_args, cli_current(c)::String)
                    cli_consume!(c)
                end
                break
            elseif !startswith(arg, "-")
                push!(host_tokens, arg)
                cli_consume!(c)
            else
                throw(ArgumentError("unknown go option: $arg"))
            end
            continue
        end
        if arg == "--output-dir"
            output_dir = cli_take_value!(c, arg)
        elseif arg == "--julia"
            julia_exe = cli_take_value!(c, arg)
        elseif arg == "--run-id"
            raw = String(strip(cli_take_value!(c, arg)))
            isempty(raw) && throw(ArgumentError("go: --run-id needs a non-empty id"))
            run_id = raw
        elseif _legacy_remote_path_arg(arg)
            _throw_legacy_remote_path("go")
        elseif arg == DEPLOY_ROOT_FLAG
            deploy_root = _set_deploy_root!(
                deploy_root, _take_deploy_root!(c), "go",
            )
        elseif arg == "--"
            options_done = true
            cli_consume!(c)
        elseif try_consume_run_option!(arg, run_opts, :go)
            cli_consume!(c)
        elseif arg == "--allow-mismatch"
            reject_removed_allow_mismatch_flag!(arg)
        elseif arg == "--repeat"
            repeat_n === nothing || throw(ArgumentError("go: --repeat given more than once"))
            repeat_n = _go_parse_repeat(cli_take_value!(c, arg))
        elseif arg in (
                "--sync",
                "--git-sync",
                "--ship-tree",
                "--allow-external-symlinks",
                "--skip-sync",
                "--skip-git-sync",
                "--skip-git-guard",
            )
            cli_consume!(c)
            _reject_run_transfer_cli!("go", arg)
        elseif arg == "--rsync"
            _throw_rsync_removed()
        elseif arg == "--help" || arg == "-h"
            cli_consume!(c)
            append!(hosts, host_tokens)
            append_kit_host_sources!(hosts, cli_session; keep_counts = true)
            if julia_exe === nothing
                env_val = get(env, "JULIA_DISTRIBUTED_EXE", "auto")
                julia_exe = env_val == "auto" ? nothing : env_val
            elseif julia_exe == "auto"
                julia_exe = nothing
            end
            return _go_parsed(;
                help = true,
                show_version = cli_session.show_version,
                cli_session = cli_session,
                script_path = script_path,
                script_args = script_args,
                hosts = hosts,
                output_dir = output_dir,
                julia = julia_exe,
                repeat = repeat_n,
                run_opts = run_opts,
                run_id = run_id,
                deploy_root = deploy_root,
            )
        elseif endswith(arg, ".jl")
            script_path = arg
            cli_consume!(c)
            while !cli_at_end(c)
                push!(script_args, cli_current(c)::String)
                cli_consume!(c)
            end
            break
        elseif !startswith(arg, "-")
            push!(host_tokens, arg)
            cli_consume!(c)
        else
            throw(ArgumentError("unknown go option: $arg"))
        end
    end
    append!(hosts, host_tokens)
    append_kit_host_sources!(hosts, cli_session; keep_counts = true)
    for h in hosts
        DistSSHBase.parse_machine_token(h)
    end
    if julia_exe === nothing
        env_val = get(env, "JULIA_DISTRIBUTED_EXE", "auto")
        julia_exe = env_val == "auto" ? nothing : env_val
    elseif julia_exe == "auto"
        julia_exe = nothing
    end
    apply_shared_cli_flags!(cli_session)
    if script_path !== nothing && repeat_n === nothing
        require_counted_placement_tokens(
            hosts;
            command = :go,
            surface = :cli,
            head_slots = cli_session.head_slots,
        )
    end
    return _go_parsed(;
        help = false,
        show_version = cli_session.show_version,
        cli_session = cli_session,
        script_path = script_path,
        script_args = script_args,
        hosts = hosts,
        output_dir = output_dir,
        julia = julia_exe,
        repeat = repeat_n,
        run_opts = run_opts,
        run_id = run_id,
        deploy_root = deploy_root,
    )
end
