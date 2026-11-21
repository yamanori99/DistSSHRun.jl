#!/usr/bin/env julia
# The `runtests.jl` file list under ParallelTestRunner.jl, one file per test, in
# worker processes. `Pkg.test()` still runs `runtests.jl`; this entry is opt-in (#530).
#   julia --project=test test/parallel.jl                   # all files, default jobs
#   julia --project=test test/parallel.jl --jobs=1
#   julia --project=test test/parallel.jl unit/DistSSHRun/main_dispatch
#   julia --project=test test/parallel.jl --list
# A name that matches no file is an error; ParallelTestRunner itself would pass with zero tests.

using ParallelTestRunner
using DistSSHRun

const ROOT = @__DIR__
const TEST_PROJECT = let active = Base.active_project()
    active === nothing && error("test/parallel.jl: Base.active_project() is nothing")
    String(active)
end

const FILES = let src = read(joinpath(ROOT, "runtests.jl"), String)
    files = String[m.captures[1] for m in eachmatch(r"_runtest_include\(\s*\"([^\"]+)\"", src)]
    isempty(files) && error("test/parallel.jl: no _runtest_include calls in runtests.jl")
    group = strip(get(ENV, "DISTSSH_TEST_GROUP", ""))
    isempty(group) ? files : filter(startswith(group * "/"), files)
end

const TESTSUITE = Dict{String, Expr}(
    replace(rel, r"\.jl$" => "") => :(Base.invokelatest(Main._ptr_include, $rel, $(joinpath(ROOT, rel))))
        for rel in FILES
)

const INIT_WORKER = Expr(
    :toplevel,
    :(const TEST_PROJECT = $TEST_PROJECT),
    :(using Test),
    :(using DistSSHRun),
    :(include($(joinpath(ROOT, "support.jl")))),
    :(DistSSHRun.set_kit_verbosity!(:progress)),
    quote
        function _ptr_include(rel::AbstractString, path::AbstractString)
            mktemp() do err_path, err_io
                redirect_stderr(err_io) do
                    Base.include(Main, path)
                end
                flush(err_io)
                text = read(err_path, String)
                print(stderr, text)
                _assert_no_binding_world_stderr!(rel, text)
            end
            return nothing
        end
    end,
)

const ARGS_PARSED = parse_args(ARGS)
for arg in ARGS_PARSED.positionals
    pat = lstrip(arg, '!')
    any(startswith(pat), keys(TESTSUITE)) || error("test/parallel.jl: $(repr(arg)) matches no test file; see --list")
end

runtests(DistSSHRun, ARGS_PARSED; testsuite = TESTSUITE, init_worker_code = INIT_WORKER)
