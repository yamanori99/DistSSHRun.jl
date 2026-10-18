# Compile bench

Precompile time, load time, CLI wall time, `src/**/*.jl` size, and the host
(OS name, arch, CPU). `code lines` skips blank lines. A row is flagged when,
against the previous sample on the same Julia slot, the host OS or arch
changes, package precompile grows by 1.5x and 0.5s, a command wall grows
by 1.5x and 1s, or a method of at least 200 ms is new in the top 20 or
doubles. This does not fail CI.

## Flagged

No sample grew past the watch line.

## 1.13

| date | commit | version | os | arch | src files | code lines | full s | pkg s | using s | help s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-17 | 1459df0 | 0.1.9 | Linux |  | 70 | 16840 | 5.8 | 2.86 | 0.31 | 1.94 |
| 2026-10-18 | e677df9 | 0.1.9 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 16840 | 6.66 | 3.32 | 0.35 | 2.09 |

```mermaid
xychart-beta
    title "1.13 help"
    x-axis ["1017", "1018"]
    y-axis "seconds" 0 --> 3
    line [1.94, 2.09]
```


Latest `help` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 1506.5 | 1389.8 |
| `Tuple{typeof(DistSSHRun.print_kit_root_usage), Base.PipeEndpoint}` | 55.8 |  |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 18.0 | 16.9 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 11.3 | 11.0 |
| `Tuple{typeof(Base.getproperty), Base.MappingRF{DistSSHRun.var"#77#78", typeof(Base.max)}, ...` | 5.3 | 5.0 |
| `Tuple{typeof(Base.indexed_iterate), Tuple{Bool, Tuple{Base.Missing, Base.Missing, Base.Mis...` | 5.1 | 4.9 |
| `Tuple{typeof(Base.getproperty), Base.Order.By{DistSSHRun.var"#_kit_progress_files##0#_kit_...` | 5.0 | 5.0 |
| `Tuple{typeof(Base.in), String, Tuple{String, String, String}}` | 4.6 | 4.7 |
| `Tuple{typeof(Base.getproperty), Base.MappingRF{DistSSHRun.var"#67#68", typeof(Base.max)}, ...` | 4.4 | 4.1 |
| `Tuple{typeof(Base.indexed_iterate), Tuple{Bool, Tuple{Base.Missing, Base.Missing, Base.Mis...` | 4.1 | 4.0 |

## 1.14-nightly

| date | commit | version | os | arch | src files | code lines | full s | pkg s | using s | help s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-17 | 1459df0 | 0.1.9 | Linux |  | 70 | 16840 | 5.78 | 3.09 | 0.34 | 1.09 |
| 2026-10-18 | e677df9 | 0.1.9 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 16840 | 4.48 | 2.36 | 0.28 | 0.89 |

```mermaid
xychart-beta
    title "1.14-nightly help"
    x-axis ["1017", "1018"]
    y-axis "seconds" 0 --> 2
    line [1.09, 0.89]
```


Latest `help` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 1116.9 | 1403.4 |
| `Tuple{typeof(DistSSHRun.print_kit_root_usage), Base.PipeEndpoint}` | 46.7 |  |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 17.3 |  |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 12.8 | 13.2 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 11.1 | 14.2 |
| `Tuple{typeof(Base.string), Char}` | 5.4 | 6.4 |
| `Tuple{typeof(Base.getproperty), Base.MappingRF{DistSSHRun.var"#77#78", typeof(Base.max)}, ...` | 5.0 | 5.7 |
| `Tuple{typeof(Base.getproperty), Base.MappingRF{DistSSHRun.var"#67#68", typeof(Base.max)}, ...` | 4.7 | 5.4 |
| `Tuple{typeof(Base.in), String, Tuple{String, String, String}}` | 4.6 | 5.2 |
| `Tuple{typeof(Base.getproperty), Base.Order.By{DistSSHRun.var"#_kit_progress_files##0#_kit_...` | 4.2 | 4.6 |

