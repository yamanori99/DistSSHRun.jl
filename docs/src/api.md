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

`WorkerPlan` is explicit local workers plus per-host counts (`N*host` tokens). `pool!` inventories cores
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

## Cluster manager surface (0.2.0)

0.2.0 freezes the user-visible API the own OpenSSH cluster manager will build on
in 0.2.x (ControlMaster wiring and sidecar land behind the same names). Today
[`drive!`](@ref) and [`ride!`](@ref) implement launch over the stock launcher;
[`LaunchReport`](@ref), ranks, seeds, and config below are the contract.

Partial worker launch is fail-closed unless you pass `best_effort=true` or CLI
`--best-effort` ([`DriveJobOptions`](@ref) `best_effort`). That replaces legacy
`--require-all-hosts` spellings.

Scoped `cluster(cfg) do … end` (deterministic worker cleanup on every exit path)
is tracked for 0.2.x ([#464](https://github.com/yamanori99/DistSSHRun.jl/issues/464)).
It is not exported in 0.2.0; adding it later is non-breaking.

```@docs
LaunchReport
launch_report_planned
launch_report_joined
launch_report_failures
launch_report_usable
LaunchIncompleteError
WorkerLaunchOutcome
HostLaunchFailure
launch_rank
SEED_SCHEME
seed_mix
worker_seed
job_item_seed
worker_pmap
RunJobConfig
BoolConfigField
StringConfigField
ConfigSource
resolve_run_job_config
resolve_run_job_config_from_parsed
run_option_table
options_for_command
unsafe_skip_env_digests_active
unsafe_expose_port_active
unsafe_all_to_all_active
unsafe_skip_env_digests_argv
with_run_unsafe_options!
with_unsafe_skip_env_digests
with_unsafe_expose_port
with_unsafe_all_to_all
DriveJobOptions
HostLaunchPlan
launch_bind_host_key
validate_all_host_launch_plans!
```

[`HostLaunchPlan`](@ref) records per-host `host`, `bind`, `tunnel`, and `topology`
for dry-run and launch. [`launch_bind_host_key`](@ref) and
[`validate_all_host_launch_plans!`](@ref) are public (not exported) entry points
for the same contract; other bind merge and override helpers stay internal.

Controller [`result_provenance`](@ref) / `run.toml` records launch under
`provenance.launch` (`planned`, `joined`, `failures` with the same keys as
[`HostLaunchFailure`](@ref)) and ranks under `provenance.seeds` (`scheme`,
`job`, `workers`, `items`).

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

`pack_ship_tree`, `pack_shipment`, and `ship_project_to_dest` ship a project
to a caller-chosen remote directory (for example a Queue qhost stage root)
without allocating `runs/<id>/` or writing Run leaf provenance. They use the
same pack rules as `ship_tree!`. Optional `transfer_id` is stored in
`<dest>/.distssh/shipment.toml` when `write_record=true` (default). The
returned `ShipmentReceipt.content_tree_hash` is the snapshot identity; callers
must not infer the latest stage from lexical paths.

`ship_tree!`, `ship_send_list`, `validate_run_id`,
`resolve_source_selection`, `read_last_ship_record`,
`write_last_ship_record!`, `forget_last_ship_default!`, and
`active_source_selection` are public and are not exported.

```@docs
pack_ship_tree
pack_shipment
ship_project_to_dest
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
DistSSHShip.content_file_digests
DistSSHShip.chmod_shipped_files_readonly!
DistSSHShip.source_had_execute_bit
DistSSHShip.shipped_regular_file_mode
DistSSHShip.apply_shipped_tree_file_modes!
DistSSHShip.shipped_file_digest_mismatches
DistSSHShip.shipped_file_mode_violations
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
        :LaunchReport, :launch_report_planned, :launch_report_joined, :launch_report_failures,
        :launch_report_usable, :LaunchIncompleteError, :WorkerLaunchOutcome, :HostLaunchFailure,
        :launch_rank, :SEED_SCHEME, :seed_mix, :job_item_seed,
        :RunJobConfig, :BoolConfigField, :StringConfigField, :ConfigSource,
        :resolve_run_job_config, :resolve_run_job_config_from_parsed,
        :run_option_table, :options_for_command,
        :unsafe_skip_env_digests_active, :unsafe_expose_port_active, :unsafe_all_to_all_active,
        :unsafe_skip_env_digests_argv, :with_run_unsafe_options!, :with_unsafe_skip_env_digests,
        :with_unsafe_expose_port, :with_unsafe_all_to_all, :DriveJobOptions,
        :HostLaunchPlan, :launch_bind_host_key, :validate_all_host_launch_plans!,
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
        :wait, :shell_status, :run_identity, :identity_mismatches, :LoadedCodeMismatchError,
        :ConfirmPathMismatch, :normalize_remote_confirm_path,
        :NO_COMMAND_HINT_LINES, :RUN_SUBCOMMAND_EXPECTATION,
    )
    n = try
        nameof(x)
    catch
        # A tuple or a `String` has no `nameof`. The blocks below document these.
        x === DistSSHRun.NO_COMMAND_HINT_LINES && return false
        x === DistSSHRun.RUN_SUBCOMMAND_EXPECTATION && return false
        x === DistSSHRun.SEED_SCHEME && return false
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

[`run_identity`](@ref) and [`identity_mismatches`](@ref) are public and are
not exported. [`go!`](@ref), [`ride!`](@ref), and [`drive!`](@ref) require the same Julia
build (version and commit) and DistSSH* `pkg.*` versions on every worker or go
slot. They also compare resolved Manifest and Project file SHA-256 digests
(byte-exact; CRLF differences count) when the controller has an active
Manifest. Without a controller Manifest digest, launch fails before workers
join unless you pass CLI `--unsafe-skip-env-digests`, which waives only
Manifest/Project digest checks (recorded as unverified; Julia build and
DistSSH* versions must still match). A Julia whose
`Base.GIT_VERSION_INFO.commit` is empty (some source builds and distribution
builds) cannot run DistSSH multi-host jobs: an unknown commit is a mismatch
by design, and `--unsafe-skip-env-digests` does not waive it. Add
[DistSSHKit](https://github.com/yamanori99/DistSSHKit.jl).
These names are not a command.

```@docs
run_identity
identity_mismatches
```

Drive and ride also compare each worker's loaded DistSSH component ids (from
precompile-time `COMPONENT_ID` constants, not Manifest digests). This check is
independent of `--unsafe-heterogeneous`, which still waives only Manifest/Project
digest lines from [`identity_mismatches`](@ref).

```@docs
LoadedCodeMismatchError
```
