category: changed

- Remote Tar extract and pull-back run Julia as
  `(unset JULIA_PROJECT; JULIA_LOAD_PATH=@stdlib exec … --startup-file=no --compiled-modules=existing -e)`.
  The helper uses stdlib Tar only and does not write compiled modules.
  Remote Julia is 1.13+ (`--compiled-modules=existing`).
