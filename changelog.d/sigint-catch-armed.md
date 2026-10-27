category: skip

The one-SIGINT and interrupt_grace tests waited on a file written before the catch. Julia 1.13 can take that SIGINT at the next safepoint and exit with a count of 0. The file is now written inside the catch.
