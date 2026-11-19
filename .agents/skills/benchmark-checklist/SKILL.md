---
name: benchmark-checklist
description: Before a compile-bench number, say what was measured and what was ignored.
disable-model-invocation: true
---

# Benchmark checklist

Use this before reporting a compile-bench number. Answer from a run.

Write the claim in the words you would ship. Read the measurement script and note what it times and what it ignores.

The gate is the same claim on macOS and on Linux. The tools are not. On Linux, core count is `nproc`. On macOS, it is `sysctl -n hw.ncpu`. Do not require `pidstat`, `strace`, or `perf`. If this OS cannot show the limiter, say that and do not borrow the other OS's profile.

1. Name the limiter from a run you do not report as the result.
2. Run each side the way the bench ships. If one side is untuned, do not pick a winner.
3. Check the result against a limit. A change to a small piece cannot make the whole run faster than that piece's share.
4. Count errors. A fast failure is not a speedup.
5. Run each side at least 5 times, alternating. Report the median and the range. A gap smaller than the range is no measurable difference.
6. Next to a micro result, say its share of the end-to-end compile.
7. Confirm the timed region did the work.

Lead with faster, slower, no measurable difference, or inconclusive. Give the unit, the OS, the run count, the range, and the limiter. One primary number. If you cannot name the limiter or the OS, the verdict is inconclusive.

Copyright (c) 2026 Lauren Tan. SPDX-License-Identifier: MIT
