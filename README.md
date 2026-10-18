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

| date | commit | version | os | arch | src files | code lines | full s | pkg s | using s | help s | go s | drive s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-17 | 1459df0 | 0.1.9 | Linux |  | 70 | 16840 | 5.8 | 2.86 | 0.31 | 1.94 |  |  |
| 2026-10-18 | e677df9 | 0.1.9 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 16840 | 6.66 | 3.32 | 0.35 | 2.09 |  |  |
| 2026-10-18 | 91b44e7 | 0.1.9 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 17009 | 3.88 | 1.87 | 0.2 | 0.43 | 4.8 | 17.93 |

```mermaid
xychart-beta
    title "1.13 help"
    x-axis ["1017", "1018", "1018"]
    y-axis "seconds" 0 --> 3
    line [1.94, 2.09, 0.43]
```


Latest `help` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 49.6 | 1506.5 |
| `Tuple{typeof(DistSSHRun.print_kit_root_usage), Base.PipeEndpoint}` | 34.0 | 55.8 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 11.6 | 18.0 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 9.4 | 11.3 |
| `Tuple{typeof(Base.getproperty), Base.GenericCondition{Base.ReentrantLock}, Symbol}` | 2.3 | 3.4 |
| `Tuple{typeof(Base.something), Nothing, Symbol}` | 1.9 | 2.6 |

```mermaid
xychart-beta
    title "1.13 go"
    x-axis ["1018"]
    y-axis "seconds" 0 --> 6
    bar [4.8]
```


Latest `go` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:project, :quiet, :verbosity, :yes, :sync, :args, :...` | 1953.0 |  |
| `Tuple{typeof(Main.go_main)}` | 1273.9 |  |
| `Tuple{DistSSHRun.var"#_go_run!##6#_go_run!##7"{String, String, Bool, Array{String, 1}, Not...` | 300.8 |  |
| `Tuple{DistSSHRun.var"#577#578", Array{String, 1}}` | 112.4 |  |
| `Tuple{typeof(Base.JuliaSyntax.core_parser_hook), Core.SimpleVector, String, Int64, Int64, ...` | 71.7 |  |
| `Tuple{typeof(Base.push_widen), Array{NamedTuple{(:event, :kind, :job, :label, :total, :don...` | 71.5 |  |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 50.3 |  |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:ok, :footer), Tuple{Bool, String}}, typeof(DistSSH...` | 41.5 |  |
| `Tuple{typeof(Base.addenv), Base.Cmd, Pair{String, String}}` | 38.6 |  |
| `Tuple{typeof(Base.setindex!), Base.Dict{String, Symbol}, Symbol, String}` | 34.9 |  |

```mermaid
xychart-beta
    title "1.13 drive"
    x-axis ["1018"]
    y-axis "seconds" 0 --> 22
    bar [17.93]
```


Latest `drive` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:original_args, :project_root), Tuple{Array{String,...` | 4993.5 |  |
| `Tuple{typeof(Main.drive_main)}` | 1662.4 |  |
| `Tuple{Distributed.var"#process_messages##0#process_messages##1"{Sockets.TCPSocket, Sockets...` | 796.9 |  |
| `Tuple{Distributed.var"#39#40"{Distributed.LocalManager, Array{Int64, 1}, Distributed.Worke...` | 591.6 |  |
| `Tuple{typeof(Serialization.serialize), Distributed.ClusterSerializer{Sockets.TCPSocket}, A...` | 311.7 |  |
| `Tuple{typeof(Base.print), Base.PipeEndpoint, Array{Int64, 1}, String}` | 184.3 |  |
| `Tuple{DistSSHRun.var"#575#576", Array{String, 1}}` | 112.9 |  |
| `Tuple{typeof(DistSSHRun.main)}` | 110.7 |  |
| `Tuple{typeof(Serialization.deserialize), Distributed.ClusterSerializer{Sockets.TCPSocket},...` | 110.3 |  |
| `Tuple{Distributed.var"#35#36"{Distributed.LocalManager, Base.GenericCondition{Base.AlwaysL...` | 95.3 |  |

## 1.14-nightly

| date | commit | version | os | arch | src files | code lines | full s | pkg s | using s | help s | go s | drive s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-17 | 1459df0 | 0.1.9 | Linux |  | 70 | 16840 | 5.78 | 3.09 | 0.34 | 1.09 |  |  |
| 2026-10-18 | e677df9 | 0.1.9 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 16840 | 4.6 | 2.38 | 0.31 | 0.96 |  |  |
| 2026-10-18 | 91b44e7 | 0.1.9 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 17009 | 4.9 | 2.57 | 0.32 | 0.56 | 2.95 | 11.38 |

```mermaid
xychart-beta
    title "1.14-nightly help"
    x-axis ["1017", "1018", "1018"]
    y-axis "seconds" 0 --> 2
    line [1.09, 0.96, 0.56]
```


Latest `help` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 114.3 | 1180.1 |
| `Tuple{typeof(DistSSHRun.print_kit_root_usage), Base.PipeEndpoint}` | 49.3 | 48.9 |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 19.1 | 18.2 |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 12.5 | 12.2 |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 11.9 | 12.6 |
| `Tuple{typeof(Base.string), Char}` | 6.0 | 5.5 |

```mermaid
xychart-beta
    title "1.14-nightly go"
    x-axis ["1018"]
    y-axis "seconds" 0 --> 4
    bar [2.95]
```


Latest `go` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:project, :quiet, :verbosity, :yes, :sync, :args, :...` | 2924.7 |  |
| `Tuple{typeof(Main.go_main)}` | 2047.7 |  |
| `Tuple{DistSSHRun.var"#_go_run!##6#_go_run!##7"{String, String, Bool, Array{String, 1}, Not...` | 373.4 |  |
| `Tuple{typeof(Base.push_widen), Array{NamedTuple{(:event, :kind, :job, :label, :total, :don...` | 115.3 |  |
| `Tuple{DistSSHRun.var"#577#578", Array{String, 1}}` | 82.8 |  |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 75.9 |  |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:ok, :footer), Tuple{Bool, String}}, typeof(DistSSH...` | 51.9 |  |
| `Tuple{typeof(Base.addenv), Base.Cmd, Pair{String, String}}` | 47.9 |  |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:kind,), Tuple{Symbol}}, typeof(DistSSHRun.execute_...` | 36.8 |  |
| `Tuple{typeof(Base.grow_to!), Array{NamedTuple{(:event, :kind, :job, :label, :total, :done,...` | 36.5 |  |

```mermaid
xychart-beta
    title "1.14-nightly drive"
    x-axis ["1018"]
    y-axis "seconds" 0 --> 14
    bar [11.38]
```


Latest `drive` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:original_args, :project_root), Tuple{Array{String,...` | 6885.8 |  |
| `Tuple{typeof(Main.drive_main)}` | 3359.0 |  |
| `Tuple{Distributed.var"#38#39"{Distributed.LocalManager, Array{Int64, 1}, Distributed.Worke...` | 1112.4 |  |
| `Tuple{Distributed.var"#process_messages##0#process_messages##1"{Sockets.TCPSocket, Sockets...` | 874.9 |  |
| `Tuple{typeof(Serialization.serialize), Distributed.ClusterSerializer{Sockets.TCPSocket}, A...` | 407.3 |  |
| `Tuple{typeof(DistSSHRun.main)}` | 249.9 |  |
| `Tuple{typeof(Distributed.send_connection_hdr), Sockets.TCPSocket, Bool}` | 238.1 |  |
| `Tuple{typeof(Distributed.read_worker_host_port), Base.PipeEndpoint}` | 215.5 |  |
| `Tuple{typeof(Base.print), Base.PipeEndpoint, Array{Int64, 1}, String}` | 148.8 |  |
| `Tuple{typeof(Serialization.deserialize), Distributed.ClusterSerializer{Sockets.TCPSocket},...` | 130.0 |  |

## nightly

| date | commit | version | os | arch | src files | code lines | full s | pkg s | using s | help s | go s | drive s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-18 | 91b44e7 | 0.1.9 | Ubuntu 24.04.5 LTS | x86_64 | 70 | 17009 | 6.16 | 3.18 | 0.35 | 0.62 | 3.38 | 12.97 |

```mermaid
xychart-beta
    title "nightly help"
    x-axis ["1018"]
    y-axis "seconds" 0 --> 1
    bar [0.62]
```


Latest `help` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 127.9 |  |
| `Tuple{typeof(DistSSHRun.print_kit_root_usage), Base.PipeEndpoint}` | 59.1 |  |
| `Tuple{typeof(Distributed.flush_gc_msgs)}` | 21.9 |  |
| `Tuple{Distributed.var"#start_gc_msgs_task##0#start_gc_msgs_task##1"}` | 13.8 |  |
| `Tuple{typeof(Base.should_use_main_entrypoint)}` | 12.0 |  |
| `Tuple{typeof(Base.string), Char}` | 6.8 |  |

```mermaid
xychart-beta
    title "nightly go"
    x-axis ["1018"]
    y-axis "seconds" 0 --> 5
    bar [3.38]
```


Latest `go` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:project, :quiet, :verbosity, :yes, :sync, :args, :...` | 3238.4 |  |
| `Tuple{typeof(Main.go_main)}` | 2335.1 |  |
| `Tuple{DistSSHRun.var"#_go_run!##6#_go_run!##7"{String, String, Bool, Array{String, 1}, Not...` | 420.7 |  |
| `Tuple{typeof(Base.push_widen), Array{NamedTuple{(:event, :kind, :job, :label, :total, :don...` | 137.6 |  |
| `Tuple{DistSSHRun.var"#577#578", Array{String, 1}}` | 100.1 |  |
| `Tuple{typeof(DistSSHRun.main), Array{String, 1}}` | 72.1 |  |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:ok, :footer), Tuple{Bool, String}}, typeof(DistSSH...` | 60.8 |  |
| `Tuple{typeof(Base.addenv), Base.Cmd, Pair{String, String}}` | 54.3 |  |
| `Tuple{typeof(Base.grow_to!), Array{NamedTuple{(:event, :kind, :job, :label, :total, :done,...` | 44.7 |  |
| `Tuple{typeof(Base.grow_to!), Array{NamedTuple{(:event, :kind, :job, :label, :total, :done,...` | 41.9 |  |

```mermaid
xychart-beta
    title "nightly drive"
    x-axis ["1018"]
    y-axis "seconds" 0 --> 16
    bar [12.97]
```


Latest `drive` methods:

| method | now ms | previous ms |
| --- | ---: | ---: |
| `Tuple{typeof(Core.kwcall), NamedTuple{(:original_args, :project_root), Tuple{Array{String,...` | 7738.0 |  |
| `Tuple{typeof(Main.drive_main)}` | 3802.7 |  |
| `Tuple{Distributed.var"#38#39"{Distributed.LocalManager, Array{Int64, 1}, Distributed.Worke...` | 1363.0 |  |
| `Tuple{Distributed.var"#process_messages##0#process_messages##1"{Sockets.TCPSocket, Sockets...` | 1041.2 |  |
| `Tuple{typeof(Serialization.serialize), Distributed.ClusterSerializer{Sockets.TCPSocket}, A...` | 471.8 |  |
| `Tuple{typeof(Distributed.read_worker_host_port), Base.PipeEndpoint}` | 266.5 |  |
| `Tuple{typeof(DistSSHRun.main)}` | 228.0 |  |
| `Tuple{typeof(Serialization.deserialize), Distributed.ClusterSerializer{Sockets.TCPSocket},...` | 215.2 |  |
| `Tuple{typeof(Distributed.send_connection_hdr), Sockets.TCPSocket, Bool}` | 199.7 |  |
| `Tuple{typeof(Base.print), Base.PipeEndpoint, Array{Int64, 1}, String}` | 177.5 |  |

