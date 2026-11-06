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
        :worker_pmap, :worker_seed, :go!, :GoResult, :report_go_errors,
        :drive!, :DriveResult, :HostRunResult, :DriveHostStatus, :drive_host_status,
        :KitRunResult, :KitProcess, :kit_run_result, :report_run_errors,
        :terminate!, :terminate_run!, :kit_result_from_dir, :result_run_dir, :result_provenance,
        :result_content_tree_hash, :result_remote_run_id,
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

## Size

`size!` and `pool!` measure memory and the free slots on a host.

```@autodocs
Modules = [DistSSHRun, DistSSHRun.DistSSHSize]
Public = true
Private = false
Filter = function (x)
    names = (
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
        :setup!, :sync!, :instantiate!, :ship_send_list,
        :KitSession, :HostResult, :SyncResult,
        :snapshot, :ship, :ShipSnapshot, :ShipTreeResult,
        :snapshot_directory, :snapshot_tar, :content_tree_hash,
        :ConfirmPathMismatch, :normalize_remote_confirm_path,
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
directories, and help text. Every other public name is in this list too,
including DistSSHBase, DistSSHUp, and DistSSHSize.

```@autodocs
Modules = [DistSSHRun, DistSSHRun.DistSSHBase, DistSSHRun.DistSSHUp, DistSSHRun.DistSSHSize]
Public = true
Private = false
Filter = function (x)
    grouped = (
        :worker_pmap, :worker_seed, :go!, :GoResult, :report_go_errors,
        :drive!, :DriveResult, :HostRunResult, :DriveHostStatus, :drive_host_status,
        :KitRunResult, :KitProcess, :kit_run_result, :report_run_errors,
        :terminate!, :terminate_run!, :kit_result_from_dir, :result_run_dir, :result_provenance,
        :result_content_tree_hash, :result_remote_run_id,
        :ride!, :RideResult, :print_ride,
        :size!, :WorkerPlan, :pool!, :ResourcePool, :HostInventory, :print_pool,
        :pipeline!, :PipelineConfig, :PipelineResult, :pipeline_config_from_env,
        :report_pipeline_errors,
        :collect!, :CollectResult,
        :setup!, :sync!, :instantiate!, :ship_send_list,
        :KitSession, :HostResult, :SyncResult,
        :snapshot, :ship, :ShipSnapshot, :ShipTreeResult,
        :snapshot_directory, :snapshot_tar, :content_tree_hash,
        :ALLOW_MISMATCH_FIELDS,
        :wait, :shell_status, :run_identity, :identity_mismatches, :parse_allow_mismatch,
        :ConfirmPathMismatch, :normalize_remote_confirm_path,
        :NO_COMMAND_HINT_LINES, :RUN_SUBCOMMAND_EXPECTATION,
    )
    n = try
        nameof(x)
    catch
        # A tuple or a `String` has no `nameof`. The blocks below document these.
        x === DistSSHRun.ALLOW_MISMATCH_FIELDS && return false
        x === DistSSHRun.NO_COMMAND_HINT_LINES && return false
        x === DistSSHRun.RUN_SUBCOMMAND_EXPECTATION && return false
        return true
    end
    return !(n in grouped)
end
```

`NO_COMMAND_HINT_LINES` and `RUN_SUBCOMMAND_EXPECTATION` are public and are
not exported. `print_rejected_command` prints them.

```@docs
NO_COMMAND_HINT_LINES
RUN_SUBCOMMAND_EXPECTATION
```

`shell_status` is public on DistSSHBase and is not exported.

```@docs
DistSSHBase.shell_status
```

## Identity

[`run_identity`](@ref), [`identity_mismatches`](@ref), and
[`parse_allow_mismatch`](@ref) are public and are not exported.
[`go!`](@ref), [`ride!`](@ref), and [`drive!`](@ref) keep
`--allow-mismatch` and these lines. Add
[DistSSHKit](https://github.com/yamanori99/DistSSHKit.jl).
These names are not a command.

```@docs
ALLOW_MISMATCH_FIELDS
run_identity
identity_mismatches
parse_allow_mismatch
```
