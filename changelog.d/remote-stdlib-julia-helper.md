category: changed

- Remote Tar extract and pull-back run Julia as
  `env -u JULIA_PROJECT JULIA_LOAD_PATH=@stdlib … --startup-file=no --compiled-modules=existing -e`.
  The helper uses stdlib Tar only and does not write compiled modules. The
  remote Julia must accept `--compiled-modules=existing` (1.6+).
