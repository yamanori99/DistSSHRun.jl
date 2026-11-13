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
        :DistSSHJobResult, :DetachedProcess, :kit_run_result, :report_run_errors,
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
wait(::DetachedProcess)
execute_kwargs_from_parsed
detached_launch
```

## Placement and host facts

`WorkerPlan` is explicit `parent:N` / `child:NAME:N`. `pool!` inventories cores
and RAM. `hostinfo` collects via `DistSSHBase.collect_host_facts` and prints
with `print_hostinfo` (per-host labeled layout; OS product vs kernel kept
separate; missing fields are `-`).

```@autodocs
Modules = [DistSSHRun]
Public = true
Private = false
Filter = function (x)
    names = (
        :WorkerPlan, :pool!, :ResourcePool, :HostInventory, :print_pool, :print_hostinfo,
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
`setup git-sync` and `setup instantiate`.

```@autodocs
Modules = [DistSSHRun]
Public = true
Private = false
Filter = function (x)
    names = (
        :setup!, :sync!, :instantiate!,
        :DistSSHSession, :HostResult, :SyncResult,
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

`ship_tree!`, `ship_send_list`, `validate_run_id`,
`resolve_source_selection`, `read_last_ship_record`,
`write_last_ship_record!`, `forget_last_ship_default!`, and
`active_source_selection` are public and are not exported.

```@docs
ship_send_list
ship_tree!
ShipTreeResult
SourceSelection
validate_run_id
resolve_source_selection
read_last_ship_record
write_last_ship_record!
forget_last_ship_default!
active_source_selection
remote_script_path
check_setup_options!
```

`DistSSHHeartbeat` is included by DistSSHRun and is not a `[deps]` entry.
Workers receive `DistSSHRun.DistSSHHeartbeat.WORKER_SOURCE`, not a
Manifest copy of DistSSHRun.

```@docs
DistSSHHeartbeat
```

`DistSSHShip` is included by DistSSHRun and is not a `[deps]` entry.
`ship_tree!` packs via `DistSSHShip.pack_tree` when given a project path.
Queue calls the names below on `DistSSHRun.DistSSHShip`.

```@docs
DistSSHShip
DistSSHShip.ShipProject
DistSSHShip.resolve_ship_project
DistSSHShip.gitignore_paths
DistSSHShip.selected_paths
DistSSHShip.pack_paths
DistSSHShip.pack_entry_paths
DistSSHShip.Shipment
DistSSHShip.pack_tree
DistSSHShip.ship
DistSSHShip.ShipmentReceipt
DistSSHShip.assert_extracted_tree_contained!
DistSSHShip.shipment_record_logical_path
DistSSHShip.build_shipment_record
DistSSHShip.write_shipment_record
DistSSHShip.read_shipment_record
DistSSHShip.read_shipment_record_status
DistSSHShip.shipment_record_status
DistSSHShip.verify_shipment_record
```

## Hosts, cache, and run directories

Names the commands above call: host tokens and SSH, the file cache, run
directories, and help text. Every other public name is in this list too,
including DistSSHBase, DistSSHUp, DistSSHShip, and DistSSHHeartbeat.

```@autodocs
Modules = [DistSSHRun, DistSSHRun.DistSSHBase, DistSSHRun.DistSSHUp]
Public = true
Private = false
Filter = function (x)
    grouped = (
        :worker_pmap, :worker_seed, :go!, :GoResult, :report_go_errors,
        :drive!, :DriveResult, :HostRunResult, :DriveHostStatus, :drive_host_status,
        :DistSSHJobResult, :DetachedProcess, :kit_run_result, :report_run_errors,
        :terminate!, :terminate_run!, :kit_result_from_dir, :result_run_dir, :result_provenance,
        :result_content_tree_hash, :result_remote_run_id,
        :ride!, :RideResult, :print_ride,
        :WorkerPlan, :pool!, :ResourcePool, :HostInventory, :print_pool, :print_hostinfo,
        :pipeline!, :PipelineConfig, :PipelineResult, :pipeline_config_from_env,
        :report_pipeline_errors,
        :collect!, :CollectResult,
        :setup!, :sync!, :instantiate!, :ship_send_list,
        :DistSSHSession, :HostResult, :SyncResult,
        :ship_tree!, :ShipTreeResult, :SourceSelection,
        :validate_run_id, :resolve_source_selection,
        :read_last_ship_record, :write_last_ship_record!,
        :forget_last_ship_default!,
        :active_source_selection,
        :remote_script_path, :check_setup_options!,
        :execute_kwargs_from_parsed, :detached_launch,
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
DistSSHBase.HostResult
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
