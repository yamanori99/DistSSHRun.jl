category: planned

- `setup --rsync` and `setup --sync` will refuse a `Manifest.toml` that would not ship, and git sync will refuse a path source whose `*.jl` or project files are ignored or untracked. 0.1.7 warns.
