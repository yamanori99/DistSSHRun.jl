# Job-environment verification messages (load path / package collisions / instantiate gate).

function job_package_collision_error(
        pkg_name::AbstractString,
        loaded_uuid::AbstractString,
        loaded_version::AbstractString,
        manifest_uuid::AbstractString,
        manifest_version::AbstractString,
        site::AbstractString,
    )::String
    host = string(gethostname())
    return join(
        [
            "what: package $(pkg_name) is already loaded with a different identity than the job Manifest",
            "where: $(site); host=$(host); loaded uuid=$(loaded_uuid) version=$(loaded_version); manifest uuid=$(manifest_uuid) version=$(manifest_version)",
            "why: packages loaded before the job environment can override or skew resolution even when LOAD_PATH is restricted",
            "fix: start a fresh Julia process for drive/go, or unload conflicting packages, then run with only the job `--project` on the load path",
            "note: --unsafe-skip-env-digests does not waive this check",
        ],
        "\n",
    )
end

function job_distssh_not_listed_error(
        pkg_name::AbstractString,
        project::AbstractString,
        site::AbstractString,
    )::String
    host = string(gethostname())
    q = _quoted_hint_path(project)
    return join(
        [
            "what: $(pkg_name) is not listed in the job environment",
            "where: $(site); host=$(host); project=$(project)",
            "why: workers and remote probes load DistSSH only from the job --project with JULIA_LOAD_PATH=@:@stdlib (no controller pkgdir or depot paths)",
            "fix: add $(pkg_name) to the job Project.toml [deps], run `Pkg.resolve()` / `Pkg.instantiate()`, ship the tree with setup, and list the package in the job Manifest",
            "note: run `julia --project=$(q) -e 'using Pkg; Pkg.add(\"$(pkg_name)\")'` then setup ship-tree for this project",
        ],
        "\n",
    )
end

function job_distssh_load_error(
        pkg_name::AbstractString,
        project::AbstractString,
        detail::AbstractString,
        site::AbstractString,
    )::String
    host = string(gethostname())
    err = strip(String(detail))
    isempty(err) && (err = "(no detail)")
    q = _quoted_hint_path(project)
    return join(
        [
            "what: $(pkg_name) cannot be loaded from the job environment",
            "where: $(site); host=$(host); project=$(project)",
            "why: $(err)",
            "fix: ensure $(pkg_name) is a direct job dependency with a resolvable Manifest entry, then run setup ship-tree / instantiate on workers",
            "note: probe from `julia --project=$(q)` with `JULIA_LOAD_PATH=@:@stdlib` only",
        ],
        "\n",
    )
end

function deploy_manifest_digest_mismatch_error(
        got::AbstractString,
        want::AbstractString,
        deploy_path::AbstractString,
    )::String
    got_s = isempty(got) ? "(missing)" : got[1:min(end, 12)] * "…"
    want_s = isempty(want) ? "(missing)" : want[1:min(end, 12)] * "…"
    return join(
        [
            "what: Manifest bytes do not match deploy record before instantiate",
            "where: deploy record=$(deploy_path); got=$(got_s) want=$(want_s)",
            "why: instantiate must not run until the on-disk Manifest matches the ship digest",
            "fix: re-run setup ship-tree and use setup instantiate with the matching run id",
        ],
        "\n",
    )
end
