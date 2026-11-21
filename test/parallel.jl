#!/usr/bin/env julia
# The `runtests.jl` file list under ParallelTestRunner.jl, one file per test, in
# worker processes. `Pkg.test()` still runs `runtests.jl`; this entry is opt-in (#530).
#   julia --project=test test/parallel.jl                   # all files, default jobs
#   julia --project=test test/parallel.jl --jobs=1
#   julia --project=test test/parallel.jl unit/DistSSHRun/main_dispatch
#   julia --project=test test/parallel.jl --list
# A name that matches no file is an error; ParallelTestRunner itself would pass with zero tests.

using ParallelTestRunner
using Test
using DistSSHRun

const ROOT = @__DIR__
const TEST_PROJECT = let active = Base.active_project()
    active === nothing && error("test/parallel.jl: Base.active_project() is nothing")
    String(active)
end
include(joinpath(ROOT, "support.jl"))

const FILES = _runtest_selected_files(read(joinpath(ROOT, "runtests.jl"), String))

const TESTSUITE = Dict{String, Expr}(
    replace(rel, r"\.jl$" => "") => quote
        let rel = $rel, path = $(joinpath(ROOT, rel))
            mktemp() do err_path, err_io
                redirect_stderr(err_io) do
                    _with_leak_guard(() -> include(path), rel)
                end
                flush(err_io)
                text = read(err_path, String)
                print(stderr, text)
                _assert_no_binding_world_stderr!(rel, text)
            end
        end
    end
        for rel in FILES
)

const INIT_WORKER = Expr(
    :toplevel,
    :(const TEST_PROJECT = $TEST_PROJECT),
    :(using DistSSHRun),
)

const INIT_CODE = Expr(
    :toplevel,
    :(const TEST_PROJECT = $TEST_PROJECT),
    :(using Test),
    :(using DistSSHRun),
    :(include($(joinpath(ROOT, "support.jl")))),
    :(DistSSHRun.set_kit_verbosity!(:progress)),
)

const ARGS_PARSED = parse_args(ARGS)
for arg in ARGS_PARSED.positionals
    pat = lstrip(arg, '!')
    any(startswith(pat), keys(TESTSUITE)) || error("test/parallel.jl: $(repr(arg)) matches no test file; see --list")
end

runtests(
    DistSSHRun,
    ARGS_PARSED;
    testsuite = TESTSUITE,
    init_worker_code = INIT_WORKER,
    init_code = INIT_CODE,
)
