# [API](@id API)

```@meta
CurrentModule = DistSSHRun
```

Exported names, grouped by the command they belong to. The longer guide
is the [DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/stable/).

## Run

`go!` runs a script as-is on one or more slots. `ride!` rewrites `map` and
`filter` in that script onto workers.

```@autodocs
Modules = [DistSSHRun]
Public = true
Private = false
Filter = function (x)
    names = (
        :worker_pmap, :go!, :GoResult, :report_go_errors,
        :ride!, :RideResult, :print_ride,
    )
    n = try
        nameof(x)
    catch
        return false
    end
    return n in names
end
```

## Plan and size

`plan` reads a script and reports how it would split. `size!` and `pool!`
measure memory and the free slots on a host.

```@autodocs
Modules = [DistSSHRun]
Public = true
Private = false
Filter = function (x)
    names = (
        :plan, :KitPlan, :PlanFinding, :print_plan,
        :size!, :WorkerPlan, :pool!, :ResourcePool, :HostInventory, :print_pool,
    )
    n = try
        nameof(x)
    catch
        return false
    end
    return n in names
end
```

## Drive and pipeline

`drive!` runs a script after a git check. `pipeline!` chains those runs.
`collect!` brings the outputs back.

```@autodocs
Modules = [DistSSHRun]
Public = true
Private = false
Filter = function (x)
    names = (
        :drive!, :DriveResult, :HostRunResult, :DriveHostStatus, :drive_host_status,
        :collect!, :CollectResult, :KitRunResult, :KitProcess, :kit_run_result,
        :pipeline!, :PipelineConfig, :PipelineResult, :pipeline_config_from_env,
        :report_pipeline_errors, :report_run_errors,
    )
    n = try
        nameof(x)
    catch
        return false
    end
    return n in names
end
```

## Setup

`setup!` prepares a host. `sync!` and `instantiate!` are the same jobs as
`setup --sync` and `setup --instantiate`.

```@autodocs
Modules = [DistSSHRun]
Public = true
Private = false
Filter = function (x)
    names = (
        :setup!, :sync!, :instantiate!,
        :KitSession, :HostResult, :SyncResult,
    )
    n = try
        nameof(x)
    catch
        return false
    end
    return n in names
end
```

## Hosts, cache, and run directories

Names the commands above call: host tokens and SSH, the file cache, run
directories, and help text.

```@autodocs
Modules = [DistSSHRun]
Public = true
Private = false
Filter = function (x)
    grouped = (
        :worker_pmap, :go!, :GoResult, :report_go_errors,
        :ride!, :RideResult, :print_ride,
        :plan, :KitPlan, :PlanFinding, :print_plan,
        :size!, :WorkerPlan, :pool!, :ResourcePool, :HostInventory, :print_pool,
        :drive!, :DriveResult, :HostRunResult, :DriveHostStatus, :drive_host_status,
        :collect!, :CollectResult, :KitRunResult, :KitProcess, :kit_run_result,
        :pipeline!, :PipelineConfig, :PipelineResult, :pipeline_config_from_env,
        :report_pipeline_errors, :report_run_errors,
        :setup!, :sync!, :instantiate!,
        :KitSession, :HostResult, :SyncResult,
    )
    n = try
        nameof(x)
    catch
        return true
    end
    return !(n in grouped)
end
```
