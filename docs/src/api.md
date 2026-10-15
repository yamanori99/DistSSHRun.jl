# [API](@id API)

```@meta
CurrentModule = DistSSHRun
```

Exported names, grouped by the command they belong to. The longer guide
is the [DistSSHKit manual](https://yamanori99.github.io/DistSSHKit.jl/stable/).

## Run

`go!` runs a script as-is on one or more slots. `drive!` runs a driver
script on workers. `ride!` is experimental: it rewrites `map` and `filter`
in a script onto workers.

```@autodocs
Modules = [DistSSHRun]
Public = true
Private = false
Filter = function (x)
    names = (
        :worker_pmap, :go!, :GoResult, :report_go_errors,
        :drive!, :DriveResult, :HostRunResult, :DriveHostStatus, :drive_host_status,
        :KitRunResult, :KitProcess, :kit_run_result, :report_run_errors,
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

```@docs
wait(::KitProcess)
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

## Pipeline

`pipeline!` chains runs. `collect!` brings the outputs back.

```@autodocs
Modules = [DistSSHRun]
Public = true
Private = false
Filter = function (x)
    names = (
        :pipeline!, :PipelineConfig, :PipelineResult, :pipeline_config_from_env,
        :report_pipeline_errors,
        :collect!, :CollectResult,
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
Modules = [DistSSHRun, DistSSHRun.DistSSHBase]
Public = true
Private = false
Filter = function (x)
    grouped = (
        :DistSSHBase,
        :worker_pmap, :go!, :GoResult, :report_go_errors,
        :drive!, :DriveResult, :HostRunResult, :DriveHostStatus, :drive_host_status,
        :KitRunResult, :KitProcess, :kit_run_result, :report_run_errors,
        :ride!, :RideResult, :print_ride,
        :plan, :KitPlan, :PlanFinding, :print_plan,
        :size!, :WorkerPlan, :pool!, :ResourcePool, :HostInventory, :print_pool,
        :pipeline!, :PipelineConfig, :PipelineResult, :pipeline_config_from_env,
        :report_pipeline_errors,
        :collect!, :CollectResult,
        :setup!, :sync!, :instantiate!,
        :KitSession, :HostResult, :SyncResult,
        # Family contract (`public`), not the user manual.
        :rsync_send_list,
        :PARENT_HOST_NAME,
        :cli_entry, :cli_heading, :cli_m, :cli_m_project, :cli_qhost, :cli_qhost_heading,
        :format_placement_token, :get_remote_julia_version, :julia_project_rel,
        :parse_placement_token, :remote_env_project_root, :resolve_remote_julia,
        :resolve_remote_project_root, :with_cli_entry,
        :juliaup_add_host!, :juliaup_default_host!, :juliaup_default_patch,
        :juliaup_status_lines, :juliaup_update_host!,
    )
    n = try
        nameof(x)
    catch
        return true
    end
    return !(n in grouped)
end
```
