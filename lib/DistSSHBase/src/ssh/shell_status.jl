# Shell status of one exited child. Callers that still read `exitcode` alone
# stay on that read until they switch.

"""
    shell_status(proc::Base.Process)::Int

Status of a child that has exited, using the shell's `128 + signal` rule.

A signaled process (`termsignal > 0`) returns `128 + termsignal`. Unix
records that child as `exitcode == 0` with `success` false. SIGINT is 130,
SIGPIPE is 141, SIGKILL is 137, and SIGTERM is 143. Any other exit returns
`exitcode` unchanged, including 0, 3, 127, and 255.

Throws `ArgumentError` when `proc` has not exited. Does not print, and does
not fold a signal into 1 or 255.
"""
function shell_status(proc::Base.Process)::Int
    process_exited(proc) || throw(ArgumentError("shell_status: process has not exited"))
    return _shell_status(proc.exitcode, proc.termsignal)
end

# `_drive_child_status` calls this after it accepts a loose signal number.
# A negative `termsignal` is not a live Unix status, so it stays out of here.
function _shell_status(exitcode::Integer, termsignal::Integer)::Int
    if termsignal > 0
        return 128 + Int(termsignal)
    end
    return Int(exitcode)
end
