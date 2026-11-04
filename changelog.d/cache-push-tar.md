category: breaking

- `push_cache!` sends cache blobs with stdlib Tar over SSH instead of `rsync`.
  The remote host must provide a Julia executable that can load stdlib `Tar`
  and `SHA` with `JULIA_LOAD_PATH=@stdlib`. A batch that fails is sent once
  more. Blobs already renamed into place stay.
