# Driver for the drive Ctrl-C test. Touches the marker once `main` runs,
# then keeps every worker busy until the test sends SIGINT.
# When `DISTSSHKIT_TEST_RESTORE_FILE` is set, `atexit` (registered from
# `main`, so only the driver) records the active project and the drive env
# slots after the frame has restored them.
using Distributed

function main()
    path = get(ENV, "DISTSSHKIT_TEST_RESTORE_FILE", "")
    if !isempty(path)
        atexit() do
            open(path, "w") do io
                println(io, "active=", repr(Base.ACTIVE_PROJECT[]))
                for key in (
                        "DISTRIBUTED_PROJECT_ROOT",
                        "DISTRIBUTED_REMOTE_PROJECT_ROOT",
                        "DISTRIBUTED_OUTPUT_DIR",
                        "DISTRIBUTED_RUNNER",
                    )
                    present = haskey(ENV, key)
                    println(io, key, "=", present ? repr(ENV[key]) : "absent")
                end
            end
            return nothing
        end
    end
    touch(ENV["DISTSSHKIT_TEST_SIGINT_MARKER"])
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
