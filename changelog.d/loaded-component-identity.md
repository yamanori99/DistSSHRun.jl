category: added

- Precompile-time `COMPONENT_ID` on DistSSHRun and bundled DistSSHBase (schema 1) with `_SRC_FILES` source-byte digests. Drive and ride workers compare loaded component ids to the controller; go slots use a stdin handshake in the same Julia process as the user script. Failures raise exported `LoadedCodeMismatchError` (not waived by `--unsafe-heterogeneous`). `DistSSHBase.tool_require` guards runtime loads (DistSSH family uuids refused at the boundary); drive asserts the verified worker set before user code runs.
