category: skip
The SIGINT tests armed the catch after the ready file.

- The one-SIGINT and interrupt_grace tests wrote the ready file before the catch. Julia 1.13 can take that SIGINT at the next safepoint and record a count of 0. The file is now written inside the catch.
