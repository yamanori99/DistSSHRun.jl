category: changed

- `push_cache!` sends cache blobs with stdlib Tar over SSH instead of `rsync`.
  A batch that fails is sent once more. Blobs already renamed into place stay.
