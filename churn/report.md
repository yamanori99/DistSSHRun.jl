## Source churn

Lines are non-blank `*.jl` under `src/` and `lib/*/src/`, grouped by package and area.
Columns use git history through `dce65d1` as of 2026-11-26 (JST).
Areas list only directories that hold at least one `*.jl` directly and show any 7d or 30d added/deleted lines.

**(root files)** lists `.jl` files sitting directly in a package `src/` directory, not in a subfolder.

![30-day churn summary](charts/churn-summary.png)

![Weekly churn](charts/churn-weekly.png)

![Net churn heatmap](charts/churn-heatmap.png)

Interactive charts (hover for values): [summary](charts/churn-summary.html) · [weekly](charts/churn-weekly.html) · [heatmap](charts/churn-heatmap.html).

### DistSSHBase
| area | files | LOC | +7d | −7d | net7 | +30d | −30d | net30 | %≥30d old | last touch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| ssh/ | 9 | 2269 | 618 | 170 | 448 | 1588 | 403 | 1185 | 46.8 | 2026-11-24 |
| hosts/ | 6 | 1097 | 148 | 59 | 89 | 1106 | 223 | 883 | 18.9 | 2026-11-24 |
| (root files) | 7 | 453 | 324 | 6 | 318 | 426 | 14 | 412 | 15.6 | 2026-11-24 |
| procs/ | 3 | 275 | 299 | 5 | 294 | 299 | 5 | 294 | 0.0 | 2026-11-24 |
| messages/ | 4 | 403 | 30 | 4 | 26 | 191 | 65 | 126 | 61.9 | 2026-11-22 |
| DistSSHBase.jl | 1 | 91 | 26 | 2 | 24 | 92 | 34 | 58 | 23.5 | 2026-11-24 |
| argv/ | 1 | 31 | 0 | 0 | 0 | 1 | 1 | 0 | 97.4 | 2026-11-08 |

*(root files)*: cli.jl, component_id.jl, component_src.jl, env.jl, namespace.jl, record_writer.jl, tool_require.jl.

### DistSSHHeartbeat
| area | files | LOC | +7d | −7d | net7 | +30d | −30d | net30 | %≥30d old | last touch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| (root files) | 5 | 204 | 16 | 10 | 6 | 248 | 25 | 223 | 0.0 | 2026-11-24 |
| DistSSHHeartbeat.jl | 1 | 22 | 0 | 0 | 0 | 30 | 2 | 28 | 0.0 | 2026-11-13 |

*(root files)*: config.jl, deliver.jl, monitor.jl, worker.jl, worker_source.jl.

### DistSSHRun
| area | files | LOC | +7d | −7d | net7 | +30d | −30d | net30 | %≥30d old | last touch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| infra/ | 26 | 10482 | 1675 | 573 | 1102 | 12322 | 2555 | 9767 | 12.8 | 2026-11-24 |
| (root files) | 11 | 5555 | 730 | 670 | 60 | 4023 | 1980 | 2043 | 50.9 | 2026-11-24 |
| core/drive/ | 12 | 3450 | 549 | 282 | 267 | 3011 | 1355 | 1656 | 42.1 | 2026-11-24 |
| core/setup/ | 10 | 4358 | 558 | 162 | 396 | 2892 | 633 | 2259 | 44.3 | 2026-11-24 |
| argv/ | 8 | 2525 | 210 | 137 | 73 | 2138 | 1007 | 1131 | 43.6 | 2026-11-24 |
| drive/ | 7 | 2160 | 550 | 309 | 241 | 1882 | 1086 | 796 | 64.4 | 2026-11-23 |
| cli/ | 15 | 1157 | 41 | 40 | 1 | 1146 | 727 | 419 | 59.9 | 2026-11-24 |
| options/ | 9 | 1206 | 316 | 50 | 266 | 1314 | 132 | 1182 | 6.3 | 2026-11-23 |
| messages/ | 3 | 2632 | 139 | 226 | -87 | 842 | 367 | 475 | 76.2 | 2026-11-24 |
| DistSSHRun.jl | 1 | 560 | 79 | 51 | 28 | 335 | 218 | 117 | 61.8 | 2026-11-24 |
| core/ | 1 | 172 | 48 | 28 | 20 | 214 | 28 | 186 | 0.0 | 2026-11-23 |

*(root files)*: DistSSHRun/drive.jl, DistSSHRun/execute.jl, DistSSHRun/execute_envelope.jl, DistSSHRun/go.jl, DistSSHRun/heartbeat_module.jl, DistSSHRun/hostinfo.jl, DistSSHRun/pool.jl, DistSSHRun/provenance.jl, DistSSHRun/setup.jl, DistSSHRun/ship_module.jl, DistSSHRun/up_module.jl.

### DistSSHShip
| area | files | LOC | +7d | −7d | net7 | +30d | −30d | net30 | %≥30d old | last touch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| (root files) | 8 | 2075 | 121 | 39 | 82 | 2572 | 356 | 2216 | 0.0 | 2026-11-24 |
| DistSSHShip.jl | 1 | 56 | 1 | 0 | 1 | 89 | 26 | 63 | 0.0 | 2026-11-24 |

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