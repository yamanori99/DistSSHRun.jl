#!/usr/bin/env julia
"""
`julia -m DistSSHKit up` — align a host's Julia channel with juliaup.

  julia --project=. -m DistSSHKit up add 1.13 child:host1
  julia --project=. -m DistSSHKit up default 1.13 parent
  julia --project=. -m DistSSHKit up update child:host1
  julia --project=. -m DistSSHKit up status parent

See `--help`.
"""

if !isdefined(@__MODULE__, :DistSSHRun)
    if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") == "1"
        import DistSSHRun
    else
        try
            import DistSSHRun
        catch
            include(joinpath(@__DIR__, "_checkout.jl"))
            _include_checkout_run()
        end
    end
end

if !isdefined(@__MODULE__, :parse_up_args)
    include(joinpath(@__DIR__, "up", "_using.jl"))
end

if !isdefined(@__MODULE__, :up_main)
    function up_main()::Cint
        opts = try
            parse_up_args(ARGS)
        catch e
            e isa ArgumentError || rethrow()
            print_err("Error: "; bold = true)
            println_fatal(e.msg)
            println_fatal()
            show_up_usage()
            return 1
        end

        if opts.show_version
            DistSSHRun.println_kit_version()
            return 0
        end

        if opts.show_help || isempty(opts.verb) || isempty(opts.hosts)
            show_up_usage()
            return opts.show_help ? 0 : 1
        end

        try
            validate_setup_hosts(opts.hosts; allow_parent = true)
        catch e
            e isa ArgumentError || rethrow()
            print_err("Error: "; bold = true)
            println_fatal(e.msg)
            println_fatal()
            show_up_usage()
            return 1
        end

        ssh_hosts = setup_juliaup_ssh_hosts(opts.hosts)
        if !isempty(ssh_hosts) && !preflight_setup_ssh(ssh_hosts)
            print_err("SSH preflight failed. Fix connectivity, then retry.")
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

if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") != "1" &&
        !isempty(PROGRAM_FILE) &&
        abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(up_main())
end
