# Compile bench

The charts are on [bench.html](https://yamanori99.github.io/DistSSHRun.jl/bench.html).

Precompile time, load time, CLI wall time, `src/**/*.jl` size, and the host
(OS name, arch, CPU). `code lines` skips blank lines. A row is flagged when,
against the previous sample on the same Julia slot, the host OS or arch
changes, the Julia version changes, package precompile grows by 1.5x and 0.5s, a command wall grows
by 1.5x and 1s, or a method of at least 200 ms is new in the top 20 or
doubles. This does not fail CI. Each slot's table folds. The 1.13
table starts open.

## Flagged

- 1.13: go method new -> 2242.7 ms: Tuple{typeof(Core.kwcall), NamedTuple{(:project, :quiet, :verbosity, :yes, :sync, :args, :path_ancho...
- 1.13: go method new -> 504.9 ms: Tuple{DistSSHRun.var"#_go_run!##6#_go_run!##7"{String, String, Bool, Array{String, 1}, Nothing, Stri...
- 1.14-pre: go method new -> 1602.1 ms: Tuple{typeof(Core.kwcall), NamedTuple{(:project, :quiet, :verbosity, :yes, :sync, :args, :path_ancho...
- 1.14-pre: go method new -> 289.2 ms: Tuple{DistSSHRun.var"#_go_run!##6#_go_run!##7"{String, String, Bool, Array{String, 1}, Nothing, Stri...
- nightly: julia 1.15.0-DEV.225 -> 1.15.0-DEV.236
- nightly: go method new -> 1307.1 ms: Tuple{typeof(Core.kwcall), NamedTuple{(:project, :quiet, :verbosity, :yes, :sync, :args, :path_ancho...
- nightly: go method new -> 246.1 ms: Tuple{DistSSHRun.var"#_go_run!##6#_go_run!##7"{String, String, Bool, Array{String, 1}, Nothing, Stri...

<details open>
<summary>1.13</summary>

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | go s | drive s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-27 | 29d24f1 | 0.1.16 | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 19100 | 21.13 | 17.85 | 0.43 | 0.88 | 6.41 | 16.55 |
| 2026-10-27 | 72bff07 | 0.1.16 | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 19156 | 22.66 | 18.92 | 0.43 | 0.88 | 6.02 | 16.93 |
| 2026-10-27 | a6b3f1c | 0.1.16 | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 19349 | 21.52 | 18.29 | 0.41 | 0.84 | 5.82 | 16.42 |
| 2026-10-27 | 5b6b167 | 0.1.16 | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 19925 | 20.76 | 17.63 | 0.4 | 0.85 | 5.65 | 15.8 |
| 2026-10-27 | 733b7af | 0.1.16 | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 19971 | 22.23 | 19.19 | 0.42 | 0.83 | 5.59 | 15.99 |
| 2026-10-27 | eefa6f1 | 0.1.16 | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 20100 | 22.45 | 19.29 | 0.42 | 0.85 | 5.83 | 16.28 |
| 2026-10-27 | 301b000 | 0.1.16 | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 20155 | 22.05 | 19.02 | 0.4 | 0.83 | 5.85 | 15.66 |
| 2026-10-27 | ac2f9fc | 0.1.16 | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 20168 | 23.75 | 20.05 | 0.42 | 0.9 | 6.15 | 16.66 |
| 2026-10-28 | e3195a6 | 0.1.16 | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 20168 | 21.99 | 18.74 | 0.39 | 0.82 | 5.66 | 15.7 |
| 2026-10-28 | 22c97c1 | 0.1.16 | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 75 | 20970 | 16.6 | 14.47 | 0.31 | 0.67 | 4.92 | 15.35 |
| 2026-10-29 | 22c97c1 | 0.1.16 | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 75 | 20970 | 22.92 | 19.85 | 0.4 | 0.83 | 6.4 | 19.2 |
| 2026-10-29 | 74d4abe | 0.1.16 | 1.13.3 | Ubuntu 26.04.1 LTS | x86_64 | 77 | 21830 | 24.98 | 21.42 | 0.43 | 0.9 | 7.12 | 20.38 |

</details>

<details>
<summary>1.14-nightly</summary>

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | go s | drive s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-22 | 03fe79f | 0.1.12 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 71 | 17854 | 6.41 | 3.48 | 0.37 | 0.65 | 4.44 | 14.6 |
| 2026-10-23 | 3b51f4b | 0.1.13 | 1.14.0-alpha1 | Ubuntu 24.04.5 LTS | x86_64 | 71 | 17854 | 3.53 | 1.85 | 0.22 | 0.43 | 2.5 | 9.6 |
| 2026-10-23 | 2a97bdd | 0.1.14 | 1.14.0-alpha1 | Ubuntu 26.04.1 LTS | x86_64 | 71 | 17895 | 4.15 | 2.14 | 0.27 | 0.51 | 3.07 | 10.56 |
| 2026-10-24 | 57acc50 | 0.1.14 | 1.14.0-alpha1 | Ubuntu 26.04.1 LTS | x86_64 | 71 | 17906 | 6.05 | 3.29 | 0.35 | 0.66 | 4.14 | 13.56 |
| 2026-10-25 | 6dc57ed | 0.1.15 | 1.14.0-alpha1.112 | Ubuntu 26.04.1 LTS | x86_64 | 71 | 17909 | 6.17 | 3.35 | 0.32 | 0.62 | 4.11 | 13.45 |
| 2026-10-26 | dc879fb | 0.1.15 | 1.14.0-alpha1.112 | Ubuntu 26.04.1 LTS | x86_64 | 71 | 17941 | 6.15 | 3.37 | 0.32 | 0.61 | 3.98 | 13.41 |
| 2026-10-26 | 28f6e13 | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 71 | 17941 | 6.34 | 3.42 | 0.33 | 0.61 | 4.04 | 13.59 |
| 2026-10-26 | 42dabbe | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 18148 | 12.77 | 8.86 | 0.25 | 0.5 | 1.76 | 6.66 |
| 2026-10-27 | 1e5acf2 | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 18148 | 11.92 | 8.36 | 0.23 | 0.48 | 1.62 | 6.2 |
| 2026-10-27 | 47c4d62 | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 18148 | 17.85 | 12.83 | 0.33 | 0.61 | 2.31 | 8.11 |
| 2026-10-27 | 1507f1d | 0.1.17 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 18148 | 19.29 | 13.19 | 0.35 | 0.64 | 2.37 | 8.12 |
| 2026-10-27 | ecd5350 | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 18153 | 13.06 | 9.17 | 0.26 | 0.53 | 1.86 | 7.0 |

</details>

<details>
<summary>1.14-pre</summary>

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | go s | drive s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-27 | 29d24f1 | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 19100 | 18.14 | 12.98 | 0.35 | 0.64 | 2.58 | 8.16 |
| 2026-10-27 | 72bff07 | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 19156 | 18.42 | 13.17 | 0.34 | 0.63 | 2.49 | 8.24 |
| 2026-10-27 | a6b3f1c | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 19349 | 18.27 | 13.49 | 0.34 | 0.63 | 2.52 | 8.19 |
| 2026-10-27 | 5b6b167 | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 19925 | 11.94 | 8.51 | 0.25 | 0.49 | 1.85 | 6.46 |
| 2026-10-27 | 733b7af | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 19971 | 19.0 | 13.38 | 0.33 | 0.62 | 2.49 | 8.16 |
| 2026-10-27 | eefa6f1 | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 20100 | 14.46 | 10.41 | 0.27 | 0.53 | 2.02 | 6.94 |
| 2026-10-27 | 301b000 | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 20155 | 14.92 | 10.68 | 0.28 | 0.54 | 2.07 | 7.13 |
| 2026-10-27 | ac2f9fc | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 20168 | 18.64 | 13.41 | 0.33 | 0.61 | 2.49 | 8.1 |
| 2026-10-28 | e3195a6 | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 20168 | 17.77 | 12.73 | 0.33 | 0.63 | 2.46 | 8.22 |
| 2026-10-28 | 22c97c1 | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 75 | 20970 | 20.73 | 14.44 | 0.35 | 0.68 | 3.06 | 10.64 |
| 2026-10-29 | 22c97c1 | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 75 | 20970 | 12.66 | 9.08 | 0.25 | 0.49 | 2.08 | 7.69 |
| 2026-10-29 | 74d4abe | 0.1.16 | 1.14.0-alpha2 | Ubuntu 26.04.1 LTS | x86_64 | 77 | 21830 | 15.9 | 11.43 | 0.3 | 0.59 | 2.85 | 9.4 |

</details>

<details>
<summary>nightly</summary>

| date | commit | version | julia | os | arch | src files | code lines | full s | pkg s | using s | help s | go s | drive s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-27 | 29d24f1 | 0.1.16 | 1.15.0-DEV.180 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 19100 | 17.99 | 13.0 | 0.26 | 0.55 | 2.41 | 7.87 |
| 2026-10-27 | 72bff07 | 0.1.16 | 1.15.0-DEV.180 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 19156 | 11.7 | 8.51 | 0.2 | 0.48 | 1.72 | 6.14 |
| 2026-10-27 | a6b3f1c | 0.1.16 | 1.15.0-DEV.180 | Ubuntu 26.04.1 LTS | x86_64 | 72 | 19349 | 14.07 | 10.02 | 0.22 | 0.48 | 2.01 | 6.73 |
| 2026-10-27 | 5b6b167 | 0.1.16 | 1.15.0-DEV.180 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 19925 | 18.19 | 13.14 | 0.27 | 0.56 | 2.35 | 7.97 |
| 2026-10-27 | 733b7af | 0.1.16 | 1.15.0-DEV.180 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 19971 | 14.5 | 10.7 | 0.24 | 0.47 | 2.1 | 6.73 |
| 2026-10-27 | eefa6f1 | 0.1.16 | 1.15.0-DEV.180 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 20100 | 12.1 | 9.0 | 0.24 | 0.46 | 1.87 | 6.35 |
| 2026-10-27 | 301b000 | 0.1.16 | 1.15.0-DEV.180 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 20155 | 19.17 | 13.84 | 0.28 | 0.58 | 2.54 | 8.17 |
| 2026-10-27 | ac2f9fc | 0.1.16 | 1.15.0-DEV.180 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 20168 | 19.03 | 13.64 | 0.27 | 0.54 | 2.53 | 7.94 |
| 2026-10-28 | e3195a6 | 0.1.16 | 1.15.0-DEV.186 | Ubuntu 26.04.1 LTS | x86_64 | 73 | 20168 | 17.3 | 12.45 | 0.27 | 0.54 | 2.37 | 7.83 |
| 2026-10-28 | 22c97c1 | 0.1.16 | 1.15.0-DEV.205 | Ubuntu 26.04.1 LTS | x86_64 | 75 | 20970 | 13.87 | 9.82 | 0.21 | 0.48 | 2.27 | 7.86 |
| 2026-10-29 | 22c97c1 | 0.1.16 | 1.15.0-DEV.225 | Ubuntu 26.04.1 LTS | x86_64 | 75 | 20970 | 18.04 | 12.97 | 0.26 | 0.52 | 2.88 | 9.89 |
| 2026-10-29 | 74d4abe | 0.1.16 | 1.15.0-DEV.236 | Ubuntu 26.04.1 LTS | x86_64 | 77 | 21830 | 13.89 | 9.67 | 0.21 | 0.42 | 2.43 | 8.33 |

</details>

