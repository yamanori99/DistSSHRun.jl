# Table-driven CLI flag consumption for go / drive / ride.

mutable struct RunOptionCliState
    unsafe_skip_env_digests::Bool
    unsafe_expose_port::Bool
    unsafe_all_to_all::Bool
    unsafe_master_silence_exit::Bool
    print_config::Bool
    dry_run::Bool
end

RunOptionCliState() = RunOptionCliState(false, false, false, false, false, false)

"""Reject a legacy flag with usage error naming the replacement (`DSSH-E001`)."""
function reject_legacy_run_cli_flag!(arg::AbstractString, command::AbstractString)
    replacement = get(LEGACY_CLI_FLAGS, arg, nothing)
    replacement === nothing && return nothing
    throw_removed_cli_flag!(arg, replacement; surface = String(command))
end

"""
    try_consume_run_option!(arg, state, command) -> Bool

Return `true` when `arg` was consumed. Handles table-defined boolean flags.
"""
function try_consume_run_option!(
        arg::AbstractString,
        state::RunOptionCliState,
        command::Symbol,
    )::Bool
    reject_legacy_run_cli_flag!(arg, string(command))
    row = option_row_by_cli(arg; command)
    row === nothing && return false
    row.valued && throw(ArgumentError(string(command, ": ", arg, " does not take a value")))
    key = row.key
    if key === :unsafe_skip_env_digests
        state.unsafe_skip_env_digests && throw(ArgumentError(string(command, ": ", arg, " specified more than once")))
        state.unsafe_skip_env_digests = true
    elseif key === :unsafe_expose_port
        state.unsafe_expose_port && throw(ArgumentError(string(command, ": ", arg, " specified more than once")))
        state.unsafe_expose_port = true
    elseif key === :unsafe_all_to_all
        state.unsafe_all_to_all && throw(ArgumentError(string(command, ": ", arg, " specified more than once")))
        state.unsafe_all_to_all = true
    elseif key === :unsafe_master_silence_exit
        state.unsafe_master_silence_exit &&
            throw(ArgumentError(string(command, ": ", arg, " specified more than once")))
        state.unsafe_master_silence_exit = true
    elseif key === :print_config
        state.print_config && throw(ArgumentError(string(command, ": ", arg, " specified more than once")))
        state.print_config = true
    elseif key === :dry_run
        state.dry_run && throw(ArgumentError(string(command, ": ", arg, " specified more than once")))
        state.dry_run = true
    else
        return false
    end
    return true
end

"""Merge `RunOptionCliState` into a parsed NamedTuple builder."""
function merge_run_option_cli!(nt::NamedTuple, state::RunOptionCliState)
    return merge(
        nt,
        (
            unsafe_skip_env_digests = state.unsafe_skip_env_digests,
            unsafe_expose_port = state.unsafe_expose_port,
            unsafe_all_to_all = state.unsafe_all_to_all,
            unsafe_master_silence_exit = state.unsafe_master_silence_exit,
            print_config = state.print_config,
            dry_run = state.dry_run,
        ),
    )
end

public RunOptionCliState, try_consume_run_option!, reject_legacy_run_cli_flag!, merge_run_option_cli!