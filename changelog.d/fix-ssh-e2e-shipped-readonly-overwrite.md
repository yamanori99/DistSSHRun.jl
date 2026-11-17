category: fixed

- SSH E2E: change job `test/runtests.jl` on the controller and redeploy with `setup ship-tree` instead of scp/rm on shipped remote trees.
- SSH E2E: add a unit guard that harness helpers do not scp or rm into `runs/*/src` ship paths.
