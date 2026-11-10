category: added

- A successful ship records `run_id` under `provenance.selection` in schema 1 controller `run.toml`, beside `content_tree_hash`. An absent or empty key means that ship was not recorded. `result_content_tree_hash` and `result_remote_run_id` read those strings from a `DriveResult`, `GoResult`, or `KitRunResult` and return `nothing` otherwise. `result_run_dir` also accepts `KitProcess`. These names are public and are not exported. Result fields stay off the API.
