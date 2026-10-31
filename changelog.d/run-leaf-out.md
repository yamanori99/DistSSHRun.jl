category: changed

- Ship creates an empty `out/` beside `src/` under each remote `runs/<run_id>/`. Controller provenance stays in `DISTSSHKIT_RUN_DIR/run.toml`; the remote leaf does not get that file.
