# Write remote sh bodies for shellcheck. Not part of Pkg.test: macOS and WSL
# CI images do not have shellcheck. The Actions lint workflow runs
# `shellcheck -s sh -e SC2016 -` on each file.
#
# SC2016 is "this single-quoted string contains $(...)". The fixtures put
# that there so a missing quote fails the parse, and a present quote is the note.

using DistSSHRun

const R = DistSSHRun
const B = DistSSHRun.DistSSHBase
const U = DistSSHRun.DistSSHUp
const nasty = "a'b \$(echo pwned)"
const path_tilde = "~/proj/a'b \$(echo pwned)"
const path_abs = "/tmp/a'b \$(echo pwned) ~"
const channel = "release' \$(echo pwned) ~"

function main(args)
    length(args) == 1 || error("usage: shellcheck-generated.jl DIR")
    dir = args[1]
    mkpath(dir)
    cases = Pair{String, String}[
        "juliaup-locate" => U._juliaup_locate_sh(B.remote_juliaup_candidates()),
        "juliaup-locate-nasty" => U._juliaup_locate_sh(
            [
                "/opt/a'b \$(echo pwned)",
                raw"$HOME/.juliaup/bin/juliaup",
            ]
        ),
        "juliaup-align" => U._juliaup_align_remote_sh(channel),
        "juliaup-update" => U._juliaup_update_remote_sh(),
        "juliaup-add" => U._juliaup_add_remote_sh(channel),
        "juliaup-default" => U._juliaup_default_remote_sh(channel),
        "juliaup-update-channel" => U._juliaup_update_channel_remote_sh(channel),
        "juliaup-status" => U._juliaup_status_sh(),
        "prune" => R._prune_remote_shell(path_tilde; older_days = 3, id = channel),
        "prune-abs" => R._prune_remote_shell(path_abs; older_days = 0, id = ""),
        "delete" => R._remote_delete_shell(path_tilde),
        "delete-abs" => R._remote_delete_shell(path_abs),
        "run-on-host" => B._run_on_host_remote_sh([nasty, "a b", "~"]),
        "run-on-host-julia" => B._run_on_host_remote_sh([nasty]; julia = path_abs, detect = false),
        "abs-resolve-tilde" => B._remote_abs_path_resolve_shell(path_tilde),
        "abs-resolve-abs" => B._remote_abs_path_resolve_shell(path_abs),
        "git-hash-tilde" => B._remote_git_hash_inner(path_tilde; short = 7),
        "git-hash-abs" => B._remote_git_hash_inner(path_abs),
    ]
    for (name, script) in cases
        write(joinpath(dir, name * ".sh"), script)
    end
    return nothing
end

main(ARGS)
