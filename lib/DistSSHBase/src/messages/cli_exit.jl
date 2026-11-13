# Exit status for a command. This file does not prompt and does not parse argv.

"""Usage rejected before the command ran. `with_cli_exit` returns 2."""
struct CliUsageError <: Exception
    msg::String
end

function Base.showerror(io::IO, e::CliUsageError)
    print(io, "CliUsageError: ", e.msg)
    return nothing
end

"""
    cli_parse(f)

Run a parser. An `ArgumentError` from `f` becomes [`CliUsageError`](@ref).
Any other exception propagates, including an `ArgumentError` the command
throws after parsing.
"""
function cli_parse(@nospecialize(f))
    try
        return f()
    catch e
        e isa ArgumentError || rethrow()
        throw(CliUsageError(String(e.msg)))
    end
end

function _is_epipe(e)::Bool
    return e isa Base.IOError && e.code == Base.UV_EPIPE
end

"""Write `Error: ` and `msg` to stderr. Does not print a usage page."""
function cli_report(msg::AbstractString)
    print(stderr, "Error: ")
    println(stderr, msg)
    return nothing
end

"""Ctrl-C exit code for a foreground command."""
cli_interrupted()::Cint = Cint(130)

"""
    with_cli_exit(f; report = cli_report, interrupted = cli_interrupted) -> Cint

Run `f()::Cint`.

A `CliUsageError` calls `report(msg)` and returns 2. Ctrl-C (`is_sigint`)
calls `interrupted()` and returns that `Cint`. An EPIPE `IOError` returns
141 and prints nothing. Any other exception, including a bare
`ArgumentError`, is `showerror` on stderr and returns 1.

`report` and `interrupted` run inside `without_cancel`. Without
`Base.CANCEL_TOKEN`, a second Ctrl-C can still stop them. With task
cancellation they finish under that shield.
"""
function with_cli_exit(
        @nospecialize(f::Function);
        @nospecialize(report::Function = cli_report),
        @nospecialize(interrupted::Function = cli_interrupted),
    )::Cint
    try
        return f()::Cint
    catch e
        if e isa CliUsageError
            without_cancel(() -> report(e.msg))
            return Cint(2)
        elseif is_sigint(e)
            return without_cancel(interrupted)::Cint
        elseif _is_epipe(e)
            return Cint(141)
        else
            without_cancel() do
                showerror(stderr, e)
                println(stderr)
            end
            return Cint(1)
        end
    end
end
