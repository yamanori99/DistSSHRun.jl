#!/usr/bin/env julia
# Check that Audit.lean COVER-* lines match the formalization scope.
# Usage: julia scripts/check-coverage.jl .lake/audit.out
const EXPECTED_FILES = ["lib/DistSSHBase/src/ssh/shell_status.jl"]
const EXPECTED_FNS = ["_shell_status", "shell_status"]

audit_out = only(ARGS)
lines = readlines(audit_out)
covered_files = Set(chopprefix(l, "COVER-FILE ") for l in lines if startswith(l, "COVER-FILE "))
covered_fns = Set(chopprefix(l, "COVER-FN ") for l in lines if startswith(l, "COVER-FN "))

expected_files = Set(EXPECTED_FILES)
expected_fns = Set(EXPECTED_FNS)

missing_files = setdiff(expected_files, covered_files)
missing_fns = setdiff(expected_fns, covered_fns)
unknown_files = setdiff(covered_files, expected_files)
unknown_fns = setdiff(covered_fns, expected_fns)

for f in sort(collect(missing_files))
    println("MISSING-FILE ", f)
end
for f in sort(collect(missing_fns))
    println("MISSING-FN ", f)
end
for f in sort(collect(unknown_files))
    println("UNKNOWN-FILE ", f)
end
for f in sort(collect(unknown_fns))
    println("UNKNOWN-FN ", f)
end
println(
    "FILES ",
    length(expected_files) - length(missing_files),
    "/",
    length(expected_files),
)
println(
    "FUNCTIONS ",
    length(expected_fns) - length(missing_fns),
    "/",
    length(expected_fns),
)

if isempty(missing_files) &&
        isempty(missing_fns) &&
        isempty(unknown_files) &&
        isempty(unknown_fns)
    println("COVERAGE OK")
else
    println("COVERAGE FAIL")
    exit(1)
end
