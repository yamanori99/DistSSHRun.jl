# Compile bench

Precompile time, load time, CLI wall time, `src/**/*.jl` size, and the host
(OS name, arch, CPU). `code lines` skips blank lines. A row is flagged when,
against the previous sample on the same Julia slot, the host OS or arch
changes, package precompile grows by 1.5x and 0.5s, a command wall grows
by 1.5x and 1s, or a method of at least 200 ms is new in the top 20 or
doubles. This does not fail CI.

## Flagged

- 1.13: package precompile 1.87s -> 3.56s
- 1.13: go wall 4.8s -> 8.4s
- 1.13: drive wall 17.93s -> 30.28s
- 1.13: drive method 110.3 ms -> 228.7 ms: Tuple{typeof(Serialization.deserialize), Distributed.ClusterSerializer{Sockets.TCPSocket}, Type{Core...

## 1.13

| date | commit | version | os | arch | src files | code lines | full s | pkg s | using s | help s | go s | drive s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-17 | 1459df0 | 0.1.9 | Linux |  | 70 | 16840 | 5.8 | 2.86 | 0.31 | 1.94 |  |  |
| 2026-10-18 | e677df9 | 0.1.9 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 16840 | 6.66 | 3.32 | 0.35 | 2.09 |  |  |
| 2026-10-18 | 91b44e7 | 0.1.9 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 17009 | 3.88 | 1.87 | 0.2 | 0.43 | 4.8 | 17.93 |
| 2026-10-19 | 29d47fa | 0.1.10 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 17009 | 7.05 | 3.56 | 0.34 | 0.7 | 8.4 | 30.28 |

```mermaid
xychart-beta
    title "1.13 help"
    x-axis ["1017", "1018", "1018", "1019"]
    y-axis "seconds" 0 --> 3
    line [1.94, 2.09, 0.43, 0.7]
```


Latest `help` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 86.4 | 49.6 |
| `Tuple{typeof(DistSSHRun.print_kit_root_usage), Base.PipeEndpoint}` | 59.1 | 34.0 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 19.0 | 11.6 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 11.8 | 9.4 |
| `Tuple{typeof(Base.getproperty), Base.GenericCondition{Base.ReentrantLock}, Symbol}` | 3.9 | 2.3 |
| `Tuple{typeof(Base.something), Nothing, Symbol}` | 3.2 | 1.9 |

```mermaid
xychart-beta
    title "1.13 go"
    x-axis ["1018", "1019"]
    y-axis "seconds" 0 --> 11
    line [4.8, 8.4]
```


Latest `go` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:project, :quiet, :verbosity, :yes, :sync, :args, :...` | 3486.4 | 1953.0 |
| `Tuple{typeof(Main.go_main)}` | 2252.4 | 1273.9 |
| `Tuple{DistSSHRun.var"#_go_run!##6#_go_run!##7"{String, String, Bool, Array{String, 1}, Not...` | 527.9 | 300.8 |
| `Tuple{DistSSHRun.var"#577#578", Array{String, 1}}` | 180.4 | 112.4 |
| `Tuple{typeof(Base.push_widen), Array{NamedTuple{(:event, :kind, :job, :label, :total, :don...` | 131.0 | 71.5 |
| `Tuple{typeof(Base.JuliaSyntax.core_parser_hook), Core.SimpleVector, String, Int64, Int64, ...` | 129.9 | 71.7 |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 87.7 | 50.3 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:ok, :footer), Tuple{Bool, String}}, typeof(DistSSH...` | 73.4 | 41.5 |
| `Tuple{typeof(Base.addenv), Base.Cmd, Pair{String, String}}` | 66.9 | 38.6 |
| `Tuple{typeof(Base.setindex!), Base.Dict{String, Symbol}, Symbol, String}` | 65.1 | 34.9 |

```mermaid
xychart-beta
    title "1.13 drive"
    x-axis ["1018", "1019"]
    y-axis "seconds" 0 --> 37
    line [17.93, 30.28]
```


Latest `drive` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:original_args, :project_root), Tuple{Array{String,...` | 8884.5 | 4993.5 |
| `Tuple{typeof(Main.drive_main)}` | 3009.5 | 1662.4 |
| `Tuple{Distributed.var"#process_messages##0#process_messages##1"{Sockets.TCPSocket, Sockets...` | 1364.9 | 796.9 |
| `Tuple{Distributed.var"#39#40"{Distributed.LocalManager, Array{Int64, 1}, Distributed.Worke...` | 1150.5 | 591.6 |
| `Tuple{typeof(Serialization.serialize), Distributed.ClusterSerializer{Sockets.TCPSocket}, A...` | 580.4 | 311.7 |
| `Tuple{typeof(Base.print), Base.PipeEndpoint, Array{Int64, 1}, String}` | 338.9 | 184.3 |
| `Tuple{typeof(Serialization.deserialize), Distributed.ClusterSerializer{Sockets.TCPSocket},...` | 228.7 | 110.3 |
| `Tuple{typeof(DistSSHRun.main)}` | 210.6 | 110.7 |
| `Tuple{DistSSHRun.var"#575#576", Array{String, 1}}` | 177.8 | 112.9 |
| `Tuple{Distributed.var"#35#36"{Distributed.LocalManager, Base.GenericCondition{Base.AlwaysL...` | 171.0 | 95.3 |

## 1.14-nightly

| date | commit | version | os | arch | src files | code lines | full s | pkg s | using s | help s | go s | drive s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-17 | 1459df0 | 0.1.9 | Linux |  | 70 | 16840 | 5.78 | 3.09 | 0.34 | 1.09 |  |  |
| 2026-10-18 | e677df9 | 0.1.9 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 16840 | 4.6 | 2.38 | 0.31 | 0.96 |  |  |
| 2026-10-18 | 91b44e7 | 0.1.9 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 17009 | 4.9 | 2.57 | 0.32 | 0.56 | 2.95 | 11.38 |
| 2026-10-19 | 29d47fa | 0.1.10 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 17009 | 4.31 | 2.41 | 0.32 | 0.58 | 2.79 | 11.03 |

```mermaid
xychart-beta
    title "1.14-nightly help"
    x-axis ["1017", "1018", "1018", "1019"]
    y-axis "seconds" 0 --> 2
    line [1.09, 0.96, 0.56, 0.58]
```


Latest `help` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 123.2 | 114.3 |
| `Tuple{typeof(DistSSHRun.print_kit_root_usage), Base.PipeEndpoint}` | 43.1 | 49.3 |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 16.2 | 19.1 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 15.7 | 11.9 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 11.1 | 12.5 |
| `Tuple{typeof(Base.string), Char}` | 7.9 | 6.0 |

```mermaid
xychart-beta
    title "1.14-nightly go"
    x-axis ["1018", "1019"]
    y-axis "seconds" 0 --> 4
    line [2.95, 2.79]
```


Latest `go` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:project, :quiet, :verbosity, :yes, :sync, :args, :...` | 2369.4 | 2924.7 |
| `Tuple{typeof(Main.go_main)}` | 1851.1 | 2047.7 |
| `Tuple{DistSSHRun.var"#_go_run!##6#_go_run!##7"{String, String, Bool, Array{String, 1}, Not...` | 304.1 | 373.4 |
| `Tuple{typeof(Base.push_widen), Array{NamedTuple{(:event, :kind, :job, :label, :total, :don...` | 110.2 | 115.3 |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 80.8 | 75.9 |
| `Tuple{DistSSHRun.var"#577#578", Array{String, 1}}` | 76.9 | 82.8 |
| `Tuple{typeof(Base.addenv), Base.Cmd, Pair{String, String}}` | 48.0 | 47.9 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:ok, :footer), Tuple{Bool, String}}, typeof(DistSSH...` | 43.2 | 51.9 |
| `Tuple{typeof(Base.grow_to!), Array{NamedTuple{(:event, :kind, :job, :label, :total, :done,...` | 32.1 | 36.5 |
| `Tuple{typeof(Base.grow_to!), Array{NamedTuple{(:event, :kind, :job, :label, :total, :done,...` | 31.7 | 35.6 |

```mermaid
xychart-beta
    title "1.14-nightly drive"
    x-axis ["1018", "1019"]
    y-axis "seconds" 0 --> 14
    line [11.38, 11.03]
```


Latest `drive` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:original_args, :project_root), Tuple{Array{String,...` | 5659.1 | 6885.8 |
| `Tuple{typeof(Main.drive_main)}` | 3206.4 | 3359.0 |
| `Tuple{Distributed.var"#process_messages##0#process_messages##1"{Sockets.TCPSocket, Sockets...` | 765.9 | 874.9 |
| `Tuple{Distributed.var"#38#39"{Distributed.LocalManager, Array{Int64, 1}, Distributed.Worke...` | 738.0 | 1112.4 |
| `Tuple{typeof(Serialization.serialize), Distributed.ClusterSerializer{Sockets.TCPSocket}, A...` | 388.0 | 407.3 |
| `Tuple{typeof(DistSSHRun.main)}` | 222.7 | 249.9 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:exename, :exeflags, :dir, :restrict, :env), Tuple{...` | 169.0 | 91.6 |
| `Tuple{typeof(Distributed.send_connection_hdr), Sockets.TCPSocket, Bool}` | 153.2 | 238.1 |
| `Tuple{typeof(Base.print), Base.PipeEndpoint, Array{Int64, 1}, String}` | 142.6 | 148.8 |
| `Tuple{typeof(Distributed.read_worker_host_port), Base.PipeEndpoint}` | 120.0 | 215.5 |

## nightly

| date | commit | version | os | arch | src files | code lines | full s | pkg s | using s | help s | go s | drive s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-18 | 91b44e7 | 0.1.9 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 17009 | 6.16 | 3.18 | 0.35 | 0.62 | 3.38 | 12.97 |
| 2026-10-19 | 29d47fa | 0.1.10 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 17009 | 5.97 | 3.19 | 0.34 | 0.62 | 3.45 | 13.23 |

```mermaid
xychart-beta
    title "nightly help"
    x-axis ["1018", "1019"]
    y-axis "seconds" 0 --> 1
    line [0.62, 0.62]
```


Latest `help` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 136.6 | 127.9 |
| `Tuple{typeof(DistSSHRun.print_kit_root_usage), Base.PipeEndpoint}` | 60.1 | 59.1 |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 22.1 | 21.9 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 15.5 | 12.0 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 13.9 | 13.8 |
| `Tuple{typeof(Base.string), Char}` | 8.8 | 6.8 |

```mermaid
xychart-beta
    title "nightly go"
    x-axis ["1018", "1019"]
    y-axis "seconds" 0 --> 5
    line [3.38, 3.45]
```


Latest `go` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:project, :quiet, :verbosity, :yes, :sync, :args, :...` | 3310.3 | 3238.4 |
| `Tuple{typeof(Main.go_main)}` | 2368.0 | 2335.1 |
| `Tuple{DistSSHRun.var"#_go_run!##6#_go_run!##7"{String, String, Bool, Array{String, 1}, Not...` | 427.0 | 420.7 |
| `Tuple{typeof(Base.push_widen), Array{NamedTuple{(:event, :kind, :job, :label, :total, :don...` | 139.7 | 137.6 |
| `Tuple{DistSSHRun.var"#577#578", Array{String, 1}}` | 101.8 | 100.1 |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 72.6 | 72.1 |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:ok, :footer), Tuple{Bool, String}}, typeof(DistSSH...` | 62.2 | 60.8 |
| `Tuple{typeof(Base.addenv), Base.Cmd, Pair{String, String}}` | 54.2 | 54.3 |
| `Tuple{typeof(Base.grow_to!), Array{NamedTuple{(:event, :kind, :job, :label, :total, :done,...` | 45.5 | 44.7 |
| `Tuple{typeof(Base.grow_to!), Array{NamedTuple{(:event, :kind, :job, :label, :total, :done,...` | 43.7 | 41.9 |

```mermaid
xychart-beta
    title "nightly drive"
    x-axis ["1018", "1019"]
    y-axis "seconds" 0 --> 16
    line [12.97, 13.23]
```


Latest `drive` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:original_args, :project_root), Tuple{Array{String,...` | 7779.2 | 7738.0 |
| `Tuple{typeof(Main.drive_main)}` | 3792.6 | 3802.7 |
| `Tuple{Distributed.var"#process_messages##0#process_messages##1"{Sockets.TCPSocket, Sockets...` | 1113.9 | 1041.2 |
| `Tuple{Distributed.var"#38#39"{Distributed.LocalManager, Array{Int64, 1}, Distributed.Worke...` | 1061.0 | 1363.0 |
| `Tuple{typeof(Serialization.serialize), Distributed.ClusterSerializer{Sockets.TCPSocket}, A...` | 471.4 | 471.8 |
| `Tuple{typeof(Base.push_widen), Array{NamedTuple{(:event, :kind, :job, :label, :total, :don...` | 256.5 | 141.0 |
| `Tuple{typeof(DistSSHRun.main)}` | 229.2 | 228.0 |
| `Tuple{typeof(Distributed.send_connection_hdr), Sockets.TCPSocket, Bool}` | 196.6 | 199.7 |
| `Tuple{typeof(Base.print), Base.PipeEndpoint, Array{Int64, 1}, String}` | 176.3 | 177.5 |
| `Tuple{typeof(Distributed.read_worker_host_port), Base.PipeEndpoint}` | 165.6 | 266.5 |

