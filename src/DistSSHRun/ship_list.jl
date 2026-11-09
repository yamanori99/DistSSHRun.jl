# Ship send list: paths a ship tar contains for one directory (see DistSSHShip.send_paths).

"""Gitignore walk only (no parent expansion, sort, or omit). Used in tests."""
function _ship_gitignore_send_list(root::AbstractString)::Vector{String}
    return DistSSHShip.gitignore_paths(root)
end

"""
    ship_send_list(root) -> Vector{String}

Relative paths a ship tar contains for this directory, sorted, with `/`
separators. The same paths with or without a `.git` directory.

The walk applies each `.gitignore` at `root` and below (case-sensitive).
`.git/info/exclude`, `core.excludesFile`, and a `.gitignore` above `root`
are not used. The git index is not consulted, and git is not run. `.git`
and `.distsshkit` are omitted. A tracked file that `.gitignore` names is
omitted. A gitignored `LocalPreferences.toml` stays out unless a later `!`
pattern puts it back. Declared inputs and fifos and other unshippable
nodes are omitted. Ancestor directories of a kept path are included.

This does not print the gitignored-project warning. That warning stays on
ship. `rsync_send_list` is the git list for `setup git-clone`, `setup git-sync`, and
`setup git-pull`.

The first call loads GitIgnore, which can write a compiled cache into the
active depot. It does not write the project or `run.toml`.
"""
function ship_send_list(root::AbstractString)::Vector{String}
    root_c = canonical_local_path(root)
    omit = String[input.path for input in _load_ship_inputs(root_c)]
    return DistSSHShip.send_paths(root_c; omit = omit)
end

public ship_send_list
