#!/usr/bin/env julia
"""
`julia -m DistSSHKit up` — align a host's Julia channel with juliaup.

  julia --project=. -m DistSSHKit up add 1.13 host1
  julia --project=. -m DistSSHKit up default 1.13 parent
  julia --project=. -m DistSSHKit up update host1
  julia --project=. -m DistSSHKit up status parent

See `--help`.
"""

# `find_package` is nothing when this environment does not provide DistSSHRun.
# Any other import failure (precompile, `__init__`) propagates.
if !isdefined(@__MODULE__, :DistSSHRun)
    if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") == "1"
        import DistSSHRun
    elseif Base.find_package("DistSSHRun") === nothing
        include(joinpath(@__DIR__, "_checkout.jl"))
        try
            _include_checkout_run()
            import DistSSHRun
        catch err
            _checkout_report(err, @__FILE__)
        end
    else
        import DistSSHRun
    end
end

if !isdefined(@__MODULE__, :parse_up_args)
    include(joinpath(@__DIR__, "up", "_using.jl"))
end

if !isdefined(@__MODULE__, :up_main)
    function up_main()::Cint
        return DistSSHRun.DistSSHBase.with_cli_exit() do
            opts = DistSSHRun.DistSSHBase.cli_parse(() -> parse_up_args(ARGS))

            if opts.show_version
                DistSSHRun.println_kit_version()
                return Cint(0)
            end

            if opts.show_help
                return DistSSHRun.DistSSHBase.cli_help_stdout(show_up_usage)
            end

            if isempty(opts.verb) || isempty(opts.hosts)
                return DistSSHRun.DistSSHBase.cli_required_else_help(show_up_usage)
            end

            try
                validate_setup_hosts(opts.hosts; allow_parent = true)
            catch e
                e isa ArgumentError || rethrow()
                throw(DistSSHRun.DistSSHBase.CliUsageError(String(e.msg)))
            end

            ssh_hosts = setup_juliaup_ssh_hosts(opts.hosts)
            if !isempty(ssh_hosts) && !preflight_setup_ssh(ssh_hosts)
                print_err("SSH preflight failed. Fix connectivity, then retry.\n")
                kit_println()
                return Cint(1)
            end

            result = juliaup_verb_remotes(
                opts.hosts;
                verb = opts.verb,
                channel = opts.channel,
                confirm = opts.verb == "default",
            )
            return Cint(finish_host_op!(opts.verb, result) ? 0 : 1)
        end
    end
end

if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") != "1" &&
        !isempty(PROGRAM_FILE) &&
        abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(up_main())
end