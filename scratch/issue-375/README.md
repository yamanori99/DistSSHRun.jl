# Issue 375 phase-1 repros (not product code)

From the DistSSHRun checkout:

```
JULIA_NUM_THREADS=1 julia --startup-file=no --project=. --warn-overwrite=yes scratch/issue-375/goal1_overwrite.jl
JULIA_NUM_THREADS=1 julia --startup-file=no scratch/issue-375/goal2_closure.jl
JULIA_NUM_THREADS=1 julia --startup-file=no scratch/issue-375/goal3_stall.jl
JULIA_NUM_THREADS=1 julia --startup-file=no scratch/issue-375/goal4_delivery.jl
```

Same with `julia +1.14` for 1.14. Do not export `JULIA_DEPOT_PATH` in the shell; goal4 sets it only on child `julia` commands.
