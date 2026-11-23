# Driver for the drive Ctrl-C test. Touches the marker once `main` runs,
# then keeps every worker busy before the test sends SIGINT.
# When `DISTSSH_TEST_RESTORE_FILE` is set, `atexit` (registered from
# `main`, so only the driver) records the active project and the drive env
# slots after the frame has restored them.
using Distributed

function main()
    path = get(ENV, "DISTSSH_TEST_RESTORE_FILE", "")
    if !isempty(path)
        atexit() do
            open(path, "w") do io
                println(io, "active=", repr(Base.ACTIVE_PROJECT[]))
                for key in (
                        "DISTSSH_PROJECT_ROOT",
                        "DISTSSH_REMOTE_PROJECT_ROOT",
                        "DISTSSH_OUTPUT_DIR",
                        "DISTSSH_INTERNAL_RUNNER",
                    )
                    present = haskey(ENV, key)
                    println(io, key, "=", present ? repr(ENV[key]) : "absent")
                end
            end
            return nothing
        end
    end
    touch(ENV["DISTSSH_TEST_SIGINT_MARKER"])
    # Captured here so a local worker can touch it. `main_started` is written
    # before `pmap` schedules anything.
    pmap_marker = joinpath(@__DIR__, "pmap_entered")
    pmap(
        _ -> begin
            touch(pmap_marker)
            sleep(120)
            1
        end, 1:nworkers()
    )
    return nothing
end
