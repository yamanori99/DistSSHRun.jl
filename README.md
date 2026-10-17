# Compile bench

Precompile time, load time, CLI wall time, and `src/**/*.jl` size.
`code lines` skips blank lines. A row is flagged when, against the previous
sample on the same Julia slot, package precompile grows by 1.5x and 0.5s,
a command wall grows by 1.5x and 1s, or a method of at least 200 ms is new
in the top 20 or doubles. This does not fail CI.

## Flagged

No sample grew past the watch line.

## 1.13

| date | commit | version | src files | code lines | full s | pkg s | using s | help s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-17 | 1459df0 | 0.1.9 | 70 | 16840 | 5.8 | 2.86 | 0.31 | 1.94 |

```mermaid
xychart-beta
    title "1.13 help"
    x-axis ["1017"]
    y-axis "seconds" 0 --> 3
    line [1.94]
```


Latest `help` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 1389.8 |  |
| `Tuple{typeof(DistSSHRun.print_kit_root_usage), Base.IOStream}` | 52.0 |  |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 16.9 |  |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 11.0 |  |
| `Tuple{typeof(Base.getproperty), Base.Order.By{DistSSHRun.var"#_kit_progress_files##0#_kit_...` | 5.0 |  |
| `Tuple{typeof(Base.getproperty), Base.MappingRF{DistSSHRun.var"#77#78", typeof(Base.max)}, ...` | 5.0 |  |
| `Tuple{typeof(Base.indexed_iterate), Tuple{Bool, Tuple{Base.Missing, Base.Missing, Base.Mis...` | 4.9 |  |
| `Tuple{typeof(Base.in), String, Tuple{String, String, String}}` | 4.7 |  |
| `Tuple{typeof(Base.getproperty), Base.MappingRF{DistSSHRun.var"#67#68", typeof(Base.max)}, ...` | 4.1 |  |
| `Tuple{typeof(Base.indexed_iterate), Tuple{Bool, Tuple{Base.Missing, Base.Missing, Base.Mis...` | 4.0 |  |

## 1.14-nightly

| date | commit | version | src files | code lines | full s | pkg s | using s | help s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-17 | 1459df0 | 0.1.9 | 70 | 16840 | 5.78 | 3.09 | 0.34 | 1.09 |

```mermaid
xychart-beta
    title "1.14-nightly help"
    x-axis ["1017"]
    y-axis "seconds" 0 --> 2
    line [1.09]
```


Latest `help` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 1403.4 |  |
| `Tuple{typeof(DistSSHRun.print_kit_root_usage), Base.IOStream}` | 62.0 |  |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 14.2 |  |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 13.2 |  |
| `Tuple{typeof(Base.string), Char}` | 6.4 |  |
| `Tuple{typeof(Base.getproperty), Base.MappingRF{DistSSHRun.var"#77#78", typeof(Base.max)}, ...` | 5.7 |  |
| `Tuple{typeof(Base.getproperty), Base.MappingRF{DistSSHRun.var"#67#68", typeof(Base.max)}, ...` | 5.4 |  |
| `Tuple{typeof(Base.in), String, Tuple{String, String, String}}` | 5.2 |  |
| `Tuple{typeof(Base.getproperty), Base.Order.By{DistSSHRun.var"#_kit_progress_files##0#_kit_...` | 4.6 |  |
| `Tuple{Core.TypeEgal{NamedTuple{(:init,), T} where T<:Tuple}, Tuple{Float64}}` | 0.9 |  |

