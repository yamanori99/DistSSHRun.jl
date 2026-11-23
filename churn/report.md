## Source churn

Lines are non-blank `*.jl` under `src/` and `lib/*/src/`, grouped by package and area.
Columns use git history through `45f4edf` as of 2026-11-23 (JST).
Areas list only directories that hold at least one `*.jl` directly and show any 7d or 30d added/deleted lines.

**(root files)** lists `.jl` files sitting directly in a package `src/` directory, not in a subfolder.

![30-day churn summary](charts/churn-summary.png)

![Weekly churn](charts/churn-weekly.png)

![Net churn heatmap](charts/churn-heatmap.png)

Interactive charts (hover for values): [summary](charts/churn-summary.html) · [weekly](charts/churn-weekly.html) · [heatmap](charts/churn-heatmap.html).

### DistSSHBase
| area | files | LOC | +7d | −7d | net7 | +30d | −30d | net30 | %≥30d old | last touch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| ssh/ | 9 | 2259 | 650 | 142 | 508 | 1519 | 344 | 1175 | 44.4 | 2026-11-23 |
| hosts/ | 6 | 1091 | 559 | 147 | 412 | 1093 | 216 | 877 | 18.9 | 2026-11-21 |
| messages/ | 4 | 403 | 80 | 15 | 65 | 193 | 67 | 126 | 61.7 | 2026-11-22 |
| (root files) | 5 | 288 | 227 | 3 | 224 | 240 | 11 | 229 | 25.5 | 2026-11-21 |
| procs/ | 2 | 233 | 250 | 0 | 250 | 250 | 0 | 250 | 0.0 | 2026-11-21 |
| DistSSHBase.jl | 1 | 86 | 39 | 6 | 33 | 87 | 34 | 53 | 24.7 | 2026-11-23 |
| argv/ | 1 | 31 | 0 | 0 | 0 | 1 | 1 | 0 | 97.4 | 2026-11-08 |

*(root files)*: component_id.jl, component_src.jl, namespace.jl, record_writer.jl, tool_require.jl.

### DistSSHHeartbeat
| area | files | LOC | +7d | −7d | net7 | +30d | −30d | net30 | %≥30d old | last touch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| (root files) | 5 | 198 | 0 | 0 | 0 | 232 | 15 | 217 | 0.0 | 2026-11-13 |
| DistSSHHeartbeat.jl | 1 | 22 | 0 | 0 | 0 | 30 | 2 | 28 | 0.0 | 2026-11-13 |

*(root files)*: config.jl, deliver.jl, monitor.jl, worker.jl, worker_source.jl.

### DistSSHRun
| area | files | LOC | +7d | −7d | net7 | +30d | −30d | net30 | %≥30d old | last touch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| infra/ | 25 | 9935 | 3981 | 783 | 3198 | 11665 | 2470 | 9195 | 11.7 | 2026-11-23 |
| (root files) | 11 | 5502 | 1228 | 859 | 369 | 3842 | 1853 | 1989 | 50.3 | 2026-11-23 |
| core/drive/ | 12 | 3445 | 956 | 402 | 554 | 2961 | 1310 | 1651 | 40.3 | 2026-11-23 |
| core/setup/ | 10 | 4170 | 646 | 116 | 530 | 2595 | 525 | 2070 | 46.2 | 2026-11-23 |
| argv/ | 8 | 2515 | 922 | 430 | 492 | 2098 | 977 | 1121 | 40.5 | 2026-11-23 |
| drive/ | 7 | 2155 | 762 | 463 | 299 | 1818 | 1027 | 791 | 44.8 | 2026-11-23 |
| cli/ | 15 | 1157 | 435 | 296 | 139 | 1115 | 696 | 419 | 43.1 | 2026-11-23 |
| options/ | 8 | 1049 | 973 | 84 | 889 | 1134 | 114 | 1020 | 7.4 | 2026-11-23 |
| messages/ | 3 | 2763 | 457 | 36 | 421 | 767 | 151 | 616 | 77.5 | 2026-11-22 |
| DistSSHRun.jl | 1 | 541 | 114 | 70 | 44 | 368 | 217 | 151 | 54.3 | 2026-11-23 |
| core/ | 1 | 172 | 213 | 27 | 186 | 213 | 27 | 186 | 0.0 | 2026-11-23 |

*(root files)*: DistSSHRun/drive.jl, DistSSHRun/execute.jl, DistSSHRun/execute_envelope.jl, DistSSHRun/go.jl, DistSSHRun/heartbeat_module.jl, DistSSHRun/hostinfo.jl, DistSSHRun/pool.jl, DistSSHRun/provenance.jl, DistSSHRun/setup.jl, DistSSHRun/ship_module.jl, DistSSHRun/up_module.jl.

### DistSSHShip
| area | files | LOC | +7d | −7d | net7 | +30d | −30d | net30 | %≥30d old | last touch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| (root files) | 8 | 2085 | 430 | 64 | 366 | 2568 | 340 | 2228 | 0.0 | 2026-11-22 |
| DistSSHShip.jl | 1 | 55 | 9 | 0 | 9 | 88 | 26 | 62 | 0.0 | 2026-11-18 |

*(root files)*: contain.jl, deps.jl, pack.jl, project.jl, record.jl, select.jl, ship.jl, tree_manifest.jl.

### DistSSHUp
| area | files | LOC | +7d | −7d | net7 | +30d | −30d | net30 | %≥30d old | last touch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| (root files) | 6 | 602 | 0 | 0 | 0 | 59 | 61 | -2 | 91.3 | 2026-11-07 |

*(root files)*: body.jl, hosts.jl, local.jl, remote.jl, status.jl, version.jl.


### Removed paths
Paths with churn in the window but no file at HEAD.
| package | path | +30d | −30d | last touch |
| --- | --- | ---: | ---: | --- |
| DistSSHSize | `lib/DistSSHSize/src/DistSSHSize.jl` | 14 | 14 | 2026-11-08 |
| DistSSHSize | `lib/DistSSHSize/src/body.jl` | 12 | 12 | 2026-11-08 |
| DistSSHSize | `lib/DistSSHSize/src/compute_worker_plan.jl` | 45 | 45 | 2026-11-08 |
| DistSSHSize | `lib/DistSSHSize/src/worker_plan.jl` | 114 | 114 | 2026-11-08 |
| DistSSHRun | `src/DistSSHRun/argv/plan_args.jl` | 9 | 138 | 2026-11-06 |
| DistSSHRun | `src/DistSSHRun/argv/ride_args.jl` | 117 | 273 | 2026-11-21 |
| DistSSHRun | `src/DistSSHRun/argv/size_args.jl` | 14 | 150 | 2026-11-08 |
| DistSSHRun | `src/DistSSHRun/argv/size_report.jl` | 0 | 134 | 2026-11-08 |
| DistSSHRun | `src/DistSSHRun/drive/runtime/heartbeat.jl` | 0 | 49 | 2026-11-09 |
| DistSSHRun | `src/DistSSHRun/drive/size.jl` | 1 | 113 | 2026-11-08 |
| DistSSHRun | `src/DistSSHRun/infra/script_scan.jl` | 315 | 315 | 2026-11-21 |
| DistSSHRun | `src/DistSSHRun/plan.jl` | 220 | 684 | 2026-11-06 |
| DistSSHRun | `src/DistSSHRun/ride.jl` | 384 | 1147 | 2026-11-21 |
| DistSSHRun | `src/DistSSHRun/size/measure.jl` | 15 | 253 | 2026-11-08 |
| DistSSHRun | `src/DistSSHRun/size_module.jl` | 18 | 18 | 2026-11-08 |
| DistSSHRun | `src/cli/plan.jl` | 17 | 73 | 2026-11-06 |
| DistSSHRun | `src/cli/plan/_using.jl` | 0 | 6 | 2026-11-06 |
| DistSSHRun | `src/cli/ride.jl` | 113 | 176 | 2026-11-21 |
| DistSSHRun | `src/cli/ride/_using.jl` | 0 | 9 | 2026-11-21 |
| DistSSHRun | `src/cli/size/_using.jl` | 0 | 9 | 2026-11-08 |