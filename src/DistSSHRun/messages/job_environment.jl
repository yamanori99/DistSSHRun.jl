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
