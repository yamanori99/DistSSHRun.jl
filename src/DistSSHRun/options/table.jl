# Single option table for go / drive / ride (extended in later phases).

"""One row of the run-job option table."""
struct OptionRow
    key::Symbol
    cli::Union{Nothing, String}
    env::Union{Nothing, String}
    kwarg::Union{Nothing, Symbol}
    default::Any
    commands::Tuple{Vararg{Symbol}}
    help::String
    unsafe::Bool
    valued::Bool
end

OptionRow(;
        key,
        cli = nothing,
        env = nothing,
        kwarg = nothing,
        default,
        commands,
        help,
        unsafe = false,
        valued = false,
    ) = OptionRow(key, cli, env, kwarg, default, commands, help, unsafe, valued)

const RUN_JOB_COMMANDS = (:go, :drive, :ride)

"""Legacy CLI spellings → current flag (no aliases at runtime)."""
const LEGACY_CLI_FLAGS = Dict{String, String}(
    "--unsafe-heterogeneous" => "--unsafe-skip-env-digests",
)

function _bool_env(name::AbstractString; env::AbstractDict = ENV)::Union{Nothing, Bool}
    haskey(env, String(name)) || return nothing
    raw = strip(get(env, String(name), ""))
    return raw in ("1", "true", "yes", "on")
end

function run_option_table()::Vector{OptionRow}
    shared = RUN_JOB_COMMANDS
    return OptionRow[
        OptionRow(;
            key = :unsafe_skip_env_digests,
            cli = "--unsafe-skip-env-digests",
            env = "DISTSSH_UNSAFE_SKIP_ENV_DIGESTS",
            kwarg = :unsafe_skip_env_digests,
            default = false,
            commands = shared,
            help = "waive Manifest/Project digest checks only (unverified; Julia build and DistSSH* versions must match)",
            unsafe = true,
        ),
        OptionRow(;
            key = :unsafe_expose_port,
            cli = "--unsafe-expose-port",
            env = "DISTSSH_UNSAFE_EXPOSE_PORT",
            kwarg = :unsafe_expose_port,
            default = false,
            commands = shared,
            help = "allow non-loopback Distributed bind addresses on workers",
            unsafe = true,
        ),
        OptionRow(;
            key = :unsafe_all_to_all,
            cli = "--unsafe-all-to-all",
            env = "DISTSSH_UNSAFE_ALL_TO_ALL",
            kwarg = :unsafe_all_to_all,
            default = false,
            commands = shared,
            help = "allow worker-to-worker connections (not only controller ↔ worker)",
            unsafe = true,
        ),
        OptionRow(;
            key = :unsafe_master_silence_exit,
            cli = "--unsafe-master-silence-exit",
            env = "DISTSSH_UNSAFE_MASTER_SILENCE_EXIT",
            kwarg = :unsafe_master_silence_exit,
            default = false,
            commands = (:drive,),
            help = "opt-in worker self-exit when the controller (master) is silent",
            unsafe = true,
        ),
        OptionRow(;
            key = :print_config,
            cli = "--print-config",
            env = nothing,
            kwarg = :print_config,
            default = false,
            commands = shared,
            help = "print resolved configuration and provenance, then exit 0 without SSH",
        ),
        OptionRow(;
            key = :dry_run,
            cli = "--dry-run",
            env = nothing,
            kwarg = :dry_run,
            default = false,
            commands = shared,
            help = "resolve config, print launch plan, then exit 0 without SSH",
        ),
        OptionRow(;
            key = :topology,
            cli = nothing,
            env = "DISTSSH_TOPOLOGY",
            kwarg = :topology,
            default = "auto",
            commands = shared,
            help = "Distributed topology: auto or master_worker",
            valued = false,
        ),
    ]
end

"""Rows applicable to `command` (`:go`, `:drive`, or `:ride`)."""
function options_for_command(command::Symbol)::Vector{OptionRow}
    command in RUN_JOB_COMMANDS ||
        throw(ArgumentError("options_for_command: unsupported command $(repr(command))"))
    return filter(r -> command in r.commands, run_option_table())
end

function option_row_by_cli(cli_flag::AbstractString; command::Symbol)::Union{Nothing, OptionRow}
    for row in options_for_command(command)
        row.cli == cli_flag && return row
    end
    return nothing
end

function option_row_by_key(key::Symbol)::Union{Nothing, OptionRow}
    for row in run_option_table()
        row.key == key && return row
    end
    return nothing
end

"""Help text line for one option row (matches `--help` indentation)."""
function option_help_line(row::OptionRow)::String
    row.cli === nothing && return ""
    line = string("  ", row.cli)
    if row.valued
        line *= " VALUE"
    end
    return string(line, "  ", row.help)
end

"""Generated option lines for a command help page (Options section)."""
function generated_run_option_help(command::Symbol)::Vector{String}
    return String[
        option_help_line(row) for row in options_for_command(command) if row.cli !== nothing
    ]
end

public OptionRow, run_option_table, options_for_command, LEGACY_CLI_FLAGS
public option_help_line, generated_run_option_help, option_row_by_cli, option_row_by_key