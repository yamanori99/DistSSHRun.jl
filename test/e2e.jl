#!/usr/bin/env julia
# Real-SSH E2E against testenv/docker-ssh workers. Not part of Pkg.test().
# Oracle: OpenSSH + remote Julia (setup / drive / go / ride / git). Assert
# files workers write (`run_on_host` / collect). Kit-parent-side demo CSV is not
# a remote collect. Inventory: test/README.md § SSH E2E.
# Local with_kit recipes are test/integration/demos/.
#
#   testenv/docker-ssh/scripts/up.sh --e2e
#   testenv/apple-container-ssh/scripts/up.sh --e2e   # Mac Apple silicon; same suite
#   DISTSSHKIT_SSH_E2E=1 julia --project=. test/e2e.jl   # from kit root
# Inner `@testset`s print `[i/N]`. The denominator is the number of
# `_e2e_announce` calls in this file.
#   DISTSSHKIT_CODE_COVERAGE=1 …/up.sh --e2e            # + .cov (child CLI too)
#   ./.github/jetls-check.sh             # e2e.jl is a JETLS entry (not via runtests.jl)
#
# Afterward open only:
#   $(cat test/artifacts/ssh-e2e/LATEST)/SUMMARY.txt

# Startup project for helper children. Same capture as `test/runtests.jl`.
# This file is a separate entry (`up.sh --e2e`, JETLS). Guard the `const` so
# loading both files in one process does not redefine it.
if !isdefined(Main, :TEST_PROJECT)
    const TEST_PROJECT = let active = Base.active_project()
        active === nothing && error("test/e2e.jl: Base.active_project() is nothing")
        String(active)
    end
end

using Test
using Distributed
using Logging
using DistSSHRun

# The product warning stays. This suite drops only that line while `terminate!`
# reaps the detached ride, so a missed `pkill` ssh does not print.
struct _DropTaggedPkillWarn <: AbstractLogger
    logger::AbstractLogger
end

function Logging.handle_message(
        l::_DropTaggedPkillWarn,
        level,
        message,
        _module,
        group,
        id,
        filepath,
        line;
        kwargs...,
    )
    if level == Logging.Warn && occursin("Tagged worker pkill did not reach", string(message))
        return nothing
    end
    return Logging.handle_message(
        l.logger, level, message, _module, group, id, filepath, line; kwargs...,
    )
end

Logging.shouldlog(l::_DropTaggedPkillWarn, args...) = Logging.shouldlog(l.logger, args...)
Logging.min_enabled_level(l::_DropTaggedPkillWarn) = Logging.min_enabled_level(l.logger)
Logging.catch_exceptions(l::_DropTaggedPkillWarn) = Logging.catch_exceptions(l.logger)

# Same include shape as `test/runtests.jl` so JETLS follows it. Do not route
# through a non-`const` `kit_root` (JETLS then skips the include).
include(joinpath(@__DIR__, "support.jl"))
DistSSHRun.set_kit_verbosity!(:progress)

if !_ssh_e2e_enabled()
    @info "Skipping SSH E2E (set DISTSSHKIT_SSH_E2E=1 to enable)"
    exit(0)
end

const g = _docker_ssh_generated()
if !isfile(g.ssh_config) || !isfile(g.hosts_file)
    error("docker-ssh not ready: missing $(g.ssh_config). Run testenv/docker-ssh/scripts/up.sh")
end

const hosts = collect(String, _ssh_e2e_hosts())
const setup_hosts = String["child:$h" for h in hosts]
const remote_root = _ssh_e2e_remote_root()
const remote_tokens = String["child:$(hosts[1]):1", "child:$(hosts[2]):1"]
# ENV overlay for the suite (`-F` ssh config and the remote project path).
_e2e_base_env() = _ssh_e2e_env(; remote_project = remote_root)

# Same banner idea as `test/runtests.jl`. Inner `@testset`s can take minutes
# of SSH with no Test output until they finish. Adding an `_e2e_announce`
# call updates `[i/N]`.
const _E2E_N = let n = count(eachline(@__FILE__)) do line
        return occursin(r"^\s*_e2e_announce\(", line)
    end
    n > 0 || error("test/e2e.jl: no _e2e_announce calls")
    n
end
const _E2E_I = Ref(0)
# Print `[i/N]` before an inner `@testset`.
function _e2e_announce(label::AbstractString)
    _E2E_I[] += 1
    println("[$(_E2E_I[])/$_E2E_N]  $label")
    flush(stdout)
    return nothing
end

@testset "SSH E2E (docker-ssh)" verbose = true begin
    _with_ssh_e2e_suite() do suite
        proj = suite.project_remote
        _stage_ssh_e2e_remote_host!(proj)
        smoke = joinpath(proj, "smoke.jl")
        echo_script = joinpath(proj, "demos", "with_kit", "square_echo.jl")
        pi_echo = joinpath(proj, "demos", "without_kit", "pi_echo.jl")
        pi_file = joinpath(proj, "demos", "without_kit", "pi_file.jl")

        @testset "setup delete (clean slate)" begin
            _e2e_announce("setup delete (clean slate)")
            proc, out = _run_kit_setup(;
                setup_args = ["delete", "--deploy-root", remote_root, "--confirm-path", remote_root, setup_hosts...],
                project_root = proj,
                extra_env = _e2e_base_env(),
            )
            _assert_ssh_e2e_ok(suite, "setup_delete", proc, out; project = proj, kit = :setup)
            for host in hosts
                p, ssh_out = _ssh_e2e_ssh(host, "test ! -e $(remote_root)/Project.toml")
                _assert_proc_ok(p, ssh_out; label = "delete $(host) Project.toml gone")
            end
        end

        @testset "setup ship-tree" begin
            _e2e_announce("setup ship-tree")
            _ssh_e2e_ensure_remote_root!(hosts, remote_root)
            proc, out = _run_kit_setup(;
                setup_args = ["ship-tree", "--deploy-root", remote_root, setup_hosts...],
                project_root = proj,
                extra_env = _e2e_base_env(),
            )
            _assert_ssh_e2e_ok(suite, "setup_ship_tree", proc, out; project = proj, kit = :setup)
            for host in hosts
                p, ssh_out = _run_subprocess(
                    Cmd(
                        [
                            "ssh", "-F", g.ssh_config, host,
                            "test -n \"\$(ls -d $(remote_root)/runs/*/src/Project.toml 2>/dev/null)\"",
                        ]
                    )
                )
                _assert_proc_ok(p, ssh_out; label = "ship-tree $(host) Project.toml")
            end
        end

        @testset "setup instantiate" begin
            _e2e_announce("setup instantiate")
            # `--deploy-root` is the deploy root only. The ship leaf is
            # `runs/<id>/src`; select it with `--snapshot` (or the local
            # last-snapshot record written by ship-tree).
            p_src, src_out = _ssh_e2e_ssh(hosts[1], "ls -1d $(remote_root)/runs/*/src 2>/dev/null | tail -n 1")
            _assert_proc_ok(p_src, src_out; label = "ship src leaf")
            ship_src = strip(src_out)
            @test !isempty(ship_src)
            snap_id = basename(dirname(ship_src))
            proc, out = _run_kit_setup(;
                setup_args = [
                    "instantiate", "--deploy-root", remote_root, "--snapshot", snap_id,
                    setup_hosts...,
                ],
                project_root = proj,
                extra_env = _e2e_base_env(),
            )
            _assert_ssh_e2e_ok(suite, "setup_instantiate", proc, out; project = proj, kit = :setup)
        end

        @testset "setup check (major.minor; no --ignore-julia-version)" begin
            _e2e_announce("setup check (major.minor; no --ignore-julia-version)")
            # Ship does not send .git/; --check warns on a missing remote hash but
            # must still pass the Julia version string (patch and prerelease)
            # plus project/deps. A build suffix may differ. Git parity is not
            # claimed for the ship path (see docker-ssh README).
            proc, out = _run_kit_setup(;
                setup_args = ["check", "--deploy-root", remote_root, setup_hosts...],
                project_root = proj,
                extra_env = merge(_e2e_base_env(), Dict("DISTSSHKIT_QUIET" => "0")),
            )
            _assert_ssh_e2e_ok(suite, "setup_check", proc, out; project = proj, kit = :setup)
            @test occursin("Julia", out)
        end

        @testset "up (mismatch then align to kit parent)" begin
            _e2e_announce("up (mismatch then align to kit parent)")
            ch = _ssh_e2e_julia_channels()
            @test ch.alt != ch.default
            host = hosts[1]
            try
                _ssh_e2e_juliaup_default!(host, ch.alt)
                proc_bad, out_bad = _run_kit_setup(;
                    setup_args = ["check", "--deploy-root", remote_root, setup_hosts...],
                    project_root = proj,
                    extra_env = merge(_e2e_base_env(), Dict("DISTSSHKIT_QUIET" => "0")),
                )
                _ssh_e2e_record!(
                    suite, "setup_check_after_alt", proc_bad, out_bad;
                    expect_ok = false, project = proj, kit = :setup,
                )
                @test proc_bad.exitcode != 0
                @test occursin("mismatch", lowercase(out_bad)) ||
                    occursin("version", lowercase(out_bad))

                proc_up, out_up = _run_kit_up_align(
                    [ch.default, setup_hosts...];
                    project_root = proj,
                    extra_env = merge(_e2e_base_env(), Dict("DISTSSHKIT_QUIET" => "0")),
                )
                _assert_ssh_e2e_ok(suite, "setup_juliaup", proc_up, out_up; project = proj, kit = :setup)

                DistSSHRun.DistSSHBase.clear_detect_julia_path_cache!()
                withenv(_e2e_base_env()...) do
                    found = DistSSHRun.resolve_remote_julia(host, "auto")
                    @test found isa AbstractString
                    found isa AbstractString || error("expected remote julia after up")
                    ver = DistSSHRun.DistSSHBase.get_remote_julia_version(host, found)
                    @test ver isa VersionNumber
                    ver isa VersionNumber || error("expected remote version")
                    @test ver.major == VERSION.major
                    @test ver.minor == VERSION.minor
                    @test ver.patch == VERSION.patch
                    _assert_ssh_e2e_api_ok(
                        suite,
                        "juliaup_aligned_$(host)",
                        true,
                        "path=$(found) ver=$(ver) channel=$(ch.default)",
                    )
                end

                proc_ok, out_ok = _run_kit_setup(;
                    setup_args = ["check", "--deploy-root", remote_root, setup_hosts...],
                    project_root = proj,
                    extra_env = merge(_e2e_base_env(), Dict("DISTSSHKIT_QUIET" => "0")),
                )
                _assert_ssh_e2e_ok(
                    suite, "setup_check_after_juliaup", proc_ok, out_ok;
                    project = proj, kit = :setup,
                )
            finally
                for h in hosts
                    try
                        _ssh_e2e_juliaup_default!(h, ch.default)
                    catch e
                        @warn "restore juliaup default failed" host = h exception = e
                    end
                end
                DistSSHRun.DistSSHBase.clear_detect_julia_path_cache!()
            end
        end

        @testset "up parent + one remote" begin
            _e2e_announce("up parent + one remote")
            ch = _ssh_e2e_julia_channels()
            @test ch.alt != ch.default
            host = hosts[1]
            parent_restore = _ssh_e2e_local_juliaup_default_channel()
            try
                _ssh_e2e_juliaup_default_local!(ch.alt)
                _ssh_e2e_juliaup_default!(host, ch.alt)
                parent_alt = _ssh_e2e_local_juliaup_julia_version()
                alt_parts = split(ch.alt, '.')
                @test length(alt_parts) >= 2
                @test parent_alt.major == parse(Int, alt_parts[1])
                @test parent_alt.minor == parse(Int, alt_parts[2])
                @test DistSSHRun.julia_version_mismatch_kind(VERSION, parent_alt) == :minor

                proc_up, out_up = _run_kit_up_align(
                    [ch.default, "parent", DistSSHRun.setup_cli_host_token(host)];
                    project_root = proj,
                    extra_env = merge(_e2e_base_env(), Dict("DISTSSHKIT_QUIET" => "0")),
                )
                _assert_ssh_e2e_ok(
                    suite, "setup_juliaup_parent_remote", proc_up, out_up;
                    project = proj, kit = :setup,
                )
                @test occursin("add complete (2 host(s)).", out_up)
                @test occursin("default complete (2 host(s)).", out_up)

                parent_ver = _ssh_e2e_local_juliaup_julia_version()
                @test parent_ver.major == VERSION.major
                @test parent_ver.minor == VERSION.minor
                _assert_ssh_e2e_api_ok(
                    suite,
                    "juliaup_aligned_parent",
                    true,
                    "ver=$(parent_ver) channel=$(ch.default)",
                )

                DistSSHRun.DistSSHBase.clear_detect_julia_path_cache!()
                withenv(_e2e_base_env()...) do
                    found = DistSSHRun.resolve_remote_julia(host, "auto")
                    @test found isa AbstractString
                    found isa AbstractString || error("expected remote julia after up")
                    ver = DistSSHRun.DistSSHBase.get_remote_julia_version(host, found)
                    @test ver isa VersionNumber
                    ver isa VersionNumber || error("expected remote version")
                    @test ver.major == VERSION.major
                    @test ver.minor == VERSION.minor
                    _assert_ssh_e2e_api_ok(
                        suite,
                        "juliaup_aligned_$(host)_with_parent",
                        true,
                        "path=$(found) ver=$(ver) channel=$(ch.default)",
                    )
                end

                # Second remote was not a target; leave it alone. Re-check listed hosts.
                proc_ok, out_ok = _run_kit_setup(;
                    setup_args = ["check", "--deploy-root", remote_root, DistSSHRun.setup_cli_host_token(host)],
                    project_root = proj,
                    extra_env = merge(_e2e_base_env(), Dict("DISTSSHKIT_QUIET" => "0")),
                )
                _assert_ssh_e2e_ok(
                    suite, "setup_check_after_juliaup_parent", proc_ok, out_ok;
                    project = proj, kit = :setup,
                )
            finally
                try
                    _ssh_e2e_juliaup_default_local!(parent_restore)
                catch e
                    @warn "restore kit parent juliaup default failed" exception = e
                end
                try
                    _ssh_e2e_juliaup_default!(host, ch.default)
                catch e
                    @warn "restore juliaup default failed" host = host exception = e
                end
                DistSSHRun.DistSSHBase.clear_detect_julia_path_cache!()
            end
        end

        @testset "up update (default channel unchanged)" begin
            _e2e_announce("up update (default channel unchanged)")
            host = hosts[1]
            before = _ssh_e2e_juliaup_remote_default_channel(host)
            proc, out = _run_kit_setup(;
                command = "up",
                setup_args = ["update", DistSSHRun.setup_cli_host_token(host)],
                project_root = proj,
                extra_env = merge(_e2e_base_env(), Dict("DISTSSHKIT_QUIET" => "0")),
            )
            _assert_ssh_e2e_ok(
                suite, "setup_juliaup_update", proc, out;
                project = proj, kit = :setup,
            )
            after = _ssh_e2e_juliaup_remote_default_channel(host)
            @test after == before
            _assert_ssh_e2e_api_ok(
                suite,
                "juliaup_update_default_unchanged_$(host)",
                after == before,
                "channel=$(after)",
            )
        end

        @testset "setup runtest (job Pkg.test)" begin
            _e2e_announce("setup runtest (job Pkg.test)")
            proc, out = _run_kit_setup(;
                setup_args = ["runtest", "--deploy-root", remote_root, setup_hosts...],
                project_root = proj,
                extra_env = _e2e_base_env(),
            )
            _assert_ssh_e2e_ok(suite, "setup_runtest", proc, out; project = proj, kit = :setup)
        end

        @testset "setup runtest fails when job tests fail" begin
            _e2e_announce("setup runtest fails when job tests fail")
            try
                _ssh_e2e_push_job_runtests!(hosts, remote_root; fail = true)
                proc, out = _run_kit_setup(;
                    setup_args = ["runtest", "--deploy-root", remote_root, setup_hosts...],
                    project_root = proj,
                    extra_env = merge(_e2e_base_env(), Dict("DISTSSHKIT_QUIET" => "0")),
                )
                _ssh_e2e_record!(
                    suite, "setup_runtest_fail", proc, out;
                    expect_ok = false, project = proj, kit = :setup,
                )
                @test proc.exitcode != 0
            finally
                _ssh_e2e_push_job_runtests!(hosts, remote_root; fail = false)
            end
        end

        @testset "hostinfo two remotes" begin
            _e2e_announce("hostinfo two remotes")
            proc, out = _run_kit_hostinfo(;
                hostinfo_args = ["-q", remote_tokens...],
                project_root = proj,
                extra_env = merge(_e2e_base_env(), Dict("DISTSSHKIT_QUIET" => "0")),
            )
            _assert_ssh_e2e_ok(suite, "hostinfo_remotes", proc, out)
            @test occursin(hosts[1], out)
            @test occursin(hosts[2], out)
            @test occursin(" GB", out)
            @test occursin("Hostinfo:", out)
            @test !occursin("Total:", out)
        end

        @testset "drive square_echo two remotes" begin
            _e2e_announce("drive square_echo two remotes")
            proc, out = _run_kit_drive(;
                script = echo_script,
                host_root = proj,
                parent_workers = 0,
                child_hosts = remote_tokens,
                script_args = ["--n", "4"],
                drive_flags = ["-y", "-q"],
                extra_env = _e2e_base_env(),
            )
            _assert_ssh_e2e_ok(suite, "drive_square_echo", proc, out)
            @test occursin("param^2:", out)
            _assert_kit_progress_done(joinpath(proj, "demos", "with_kit", "output"); kind = :drive)
        end

        @testset "drive square_file CSV is local (kit parent main)" begin
            _e2e_announce("drive square_file CSV is local (kit parent main)")
            square_file = joinpath(proj, "demos", "with_kit", "square_file.jl")
            out_dir = joinpath(proj, "demos", "with_kit", "output")
            isdir(out_dir) && rm(out_dir; recursive = true)
            out_csv = joinpath(out_dir, "square_results.csv")
            proc, out = _run_kit_drive(;
                script = square_file,
                host_root = proj,
                parent_workers = 0,
                child_hosts = remote_tokens,
                script_args = ["--n", "4"],
                drive_flags = ["-y", "-q"],
                extra_env = _e2e_base_env(),
            )
            _assert_ssh_e2e_ok(suite, "drive_square_file", proc, out)
            @test isfile(out_csv)
            @test occursin("param,result", read(out_csv, String))
            p, _ = _ssh_e2e_ssh(hosts[1], "test ! -e $(remote_root)/demos/with_kit/output/square_results.csv")
            _assert_proc_ok(p, ""; label = "square_file CSV absent on remote")
            _assert_kit_progress_done(dirname(out_csv); kind = :drive)
        end

        @testset "drive collect bytes written on workers" begin
            _e2e_announce("drive collect bytes written on workers")
            script = joinpath(proj, "worker_file.jl")
            collect_root = joinpath(proj, "output")
            isdir(collect_root) && rm(collect_root; recursive = true)

            proc, out = _run_kit_drive(;
                script = script,
                host_root = proj,
                parent_workers = 0,
                child_hosts = remote_tokens,
                drive_flags = ["-y", "-q"],
                extra_env = _e2e_base_env(),
            )
            _assert_ssh_e2e_ok(suite, "drive_worker_file", proc, out)
            _assert_kit_progress_done(collect_root; kind = :drive)

            work_root = _ssh_e2e_work_root(hosts[1], remote_root)
            worker_jl = """
            d = $(repr(joinpath(work_root, "output")))
            io = IOBuffer()
            if isdir(d)
                for (root, _, files) in walkdir(d)
                    for name in files
                        startswith(name, "worker_") && endswith(name, ".txt") || continue
                        write(io, read(joinpath(root, name)))
                    end
                end
            end
            print(String(take!(io)))
            """
            p, remote_body = withenv(_e2e_base_env()...) do
                _e2e_run_on_host(hosts[1], ["-e", worker_jl])
            end
            _assert_proc_ok(p, remote_body; label = "run_on_host cat worker files")
            @test occursin("DISTSSHKIT_E2E_WORKER_FILE", remote_body)

            local_files = filter(
                f -> startswith(basename(f), "worker_"),
                isdir(collect_root) ? readdir(collect_root; join = true) : String[]
            )
            @test !isempty(local_files)
            @test any(f -> occursin("DISTSSHKIT_E2E_WORKER_FILE", read(f, String)), local_files)
            @test Set(h.host for h in DistSSHRun.kit_result_from_dir(collect_root).hosts) == Set(hosts)

            for f in local_files
                rm(f)
            end
            proc, out = _run_kit_drive_collect(;
                collect_root = collect_root,
                hosts = hosts,
                host_root = proj,
                extra_env = _e2e_base_env(),
            )
            _assert_ssh_e2e_ok(suite, "collect_missing", proc, out)
            local_files = filter(
                f -> startswith(basename(f), "worker_"),
                readdir(collect_root; join = true)
            )
            @test !isempty(local_files)
            let sample = local_files[1]
                @test occursin("DISTSSHKIT_E2E_WORKER_FILE", read(sample, String))

                write(sample, "LOCALJUNK\n")
                proc, out = _run_kit_drive_collect(;
                    collect_root = collect_root,
                    hosts = hosts,
                    host_root = proj,
                    extra_env = _e2e_base_env(),
                )
                _assert_ssh_e2e_ok(suite, "collect_missing_skip", proc, out)
                @test read(sample, String) == "LOCALJUNK\n"

                proc, out = _run_kit_drive_collect(;
                    collect_root = collect_root,
                    hosts = hosts,
                    overwrite = true,
                    host_root = proj,
                    extra_env = _e2e_base_env(),
                )
                _assert_ssh_e2e_ok(suite, "collect_overwrite", proc, out)
                @test occursin("DISTSSHKIT_E2E_WORKER_FILE", read(sample, String))
                @test !occursin("LOCALJUNK", read(sample, String))
            end
        end

        @testset "drive remote worker error is a real failure" begin
            _e2e_announce("drive remote worker error is a real failure")
            proc, out = _run_kit_drive(;
                script = joinpath(proj, "fail.jl"),
                host_root = proj,
                parent_workers = 0,
                child_hosts = remote_tokens,
                drive_flags = ["-y", "-q"],
                extra_env = merge(_e2e_base_env(), Dict("DISTSSHKIT_QUIET" => "0")),
            )
            _ssh_e2e_record!(
                suite, "drive_remote_error", proc, out;
                expect_ok = false, project = proj,
            )
            @test proc.exitcode != 0
            @test occursin("DISTSSHKIT_E2E_REMOTE_FAIL", out)
        end

        @testset "drive mixed local+remotes smoke" begin
            _e2e_announce("drive mixed local+remotes smoke")
            proc, out = _run_kit_drive(;
                script = smoke,
                host_root = proj,
                parent_workers = 1,
                child_hosts = remote_tokens,
                drive_flags = ["-y", "-q"],
                extra_env = _e2e_base_env(),
            )
            _assert_ssh_e2e_ok(suite, "drive_mixed", proc, out)
            @test occursin("DISTSSHKIT_RUNNER_SMOKE_OK nw=3", out)
        end

        # Focused pseudo-TTY (`script`) coverage for remote drive. Remote
        # ride under a PTY is the next inner testset (parent-side marker).
        @testset "drive remote pseudo-TTY success and failure" begin
            _e2e_announce("drive remote pseudo-TTY success and failure")
            function sh_quote(s::AbstractString)
                return "'" * replace(String(s), "'" => "'\\''") * "'"
            end
            function argv_line(cmd::Cmd)
                return join(sh_quote.(String.(cmd.exec)), " ")
            end
            tty_extra = merge(
                _e2e_base_env(),
                Dict(
                    "DISTSSHKIT_QUIET" => "0",
                    "DISTSSHKIT_YES" => "1",
                    "DISTRIBUTED_INIT_DELAY_SEC" => "0",
                ),
            )
            delete!(tty_extra, "DISTSSHKIT_PROGRESS")
            delete!(tty_extra, "DISTSSHKIT_VERBOSE")
            tty_env = _drive_host_env(proj; extra_env = tty_extra)
            ok_cmd = _kit_drive_cmd(;
                script = smoke,
                host_root = proj,
                parent_workers = 1,
                child_hosts = remote_tokens,
                drive_flags = ["-y"],
                extra_env = tty_extra,
            )
            fail_cmd = _kit_drive_cmd(;
                script = joinpath(proj, "fail.jl"),
                host_root = proj,
                parent_workers = 0,
                child_hosts = remote_tokens,
                drive_flags = ["-y"],
                extra_env = tty_extra,
            )
            mktempdir() do dir
                runner = joinpath(dir, "drive_remote_tty.sh")
                exports = join(
                    ["export $(sh_quote(k))=$(sh_quote(v))" for (k, v) in sort!(collect(pairs(tty_env)))],
                    "\n",
                )
                write(
                    runner,
                    """
                    #!/bin/sh
                    unset DISTSSHKIT_QUIET
                    unset DISTSSHKIT_PROGRESS
                    unset DISTSSHKIT_VERBOSE
                    unset DISTSSHKIT_CLI_SUBCOMMAND_DONE
                    unset DIST_SSH_KIT_CLI_INCLUDE
                    export JULIA_LOAD_PATH=$(sh_quote(_child_load_path()))
                    unset JULIA_PROJECT
                    $exports
                    unset NO_COLOR
                    $(argv_line(ok_cmd))
                    echo '___SPLIT___'
                    $(argv_line(fail_cmd))
                    """,
                )
                chmod(runner, 0o755)
                t0 = time()
                pty = _tty_capture_script(
                    runner;
                    typescript = joinpath(dir, "drive_remote_typescript.txt"),
                    hang_s = 600.0,
                )
                elapsed = time() - t0
                @info "e2e drive remote progress_tty script child wall" elapsed
                parts = split(pty, "___SPLIT___")
                @test length(parts) == 2
                ok_tty = length(parts) == 2 ? parts[1] : ""
                fail_tty = length(parts) == 2 ? parts[2] : ""
                ok_plain = _tty_strip_ansi(ok_tty)
                fail_plain = _tty_strip_ansi(fail_tty)
                @test occursin("DISTSSHKIT_RUNNER_SMOKE_OK", ok_plain)
                @test occursin("child-1", ok_plain) || occursin("child-2", ok_plain) ||
                    occursin("parent", ok_plain) || occursin("nw=3", ok_plain)
                _assert_tty_progress_payload(ok_tty)
                @test occursin("DISTSSHKIT_E2E_REMOTE_FAIL", fail_plain)
                @test any(
                    l -> occursin("DISTSSHKIT_E2E_REMOTE_FAIL", l) && !_tty_bar_line(l),
                    _tty_lines(fail_tty),
                )
                _assert_tty_progress_payload(fail_tty)
                _assert_ssh_e2e_api_ok(
                    suite, "drive_remote_tty", true, "pty ok/fail captured",
                )
            end
        end

        # Ride progress stdout is buffered then replayed after
        # `kit_progress_done!` (unlike drive `--no-log` live). Success must
        # not print `Script:`; controller `run.toml` has no `log_dir`.
        @testset "ride remote pseudo-TTY success and failure" begin
            _e2e_announce("ride remote pseudo-TTY success and failure")
            function sh_quote(s::AbstractString)
                return "'" * replace(String(s), "'" => "'\\''") * "'"
            end
            function argv_line(cmd::Cmd)
                return join(sh_quote.(String.(cmd.exec)), " ")
            end
            tty_extra = merge(
                _e2e_base_env(),
                Dict(
                    "DISTSSHKIT_QUIET" => "0",
                    "DISTSSHKIT_YES" => "1",
                    "DISTRIBUTED_INIT_DELAY_SEC" => "0",
                ),
            )
            delete!(tty_extra, "DISTSSHKIT_PROGRESS")
            delete!(tty_extra, "DISTSSHKIT_VERBOSE")
            tty_env = _drive_host_env(proj; extra_env = tty_extra)
            mktempdir() do dir
                ok_script = joinpath(dir, "ride_remote_ok.jl")
                fail_script = joinpath(dir, "ride_remote_fail.jl")
                cp(_fixture("ride_remote_ok.jl"), ok_script; force = true)
                cp(_fixture("ride_remote_fail.jl"), fail_script; force = true)
                od_ok = joinpath(dir, "ride-out-ok")
                od_fail = joinpath(dir, "ride-out-fail")
                mkpath(od_ok)
                mkpath(od_fail)
                ride_ok = _kit_cli_cmd(
                    [
                        "ride", "-y", "--no-spi-check",
                        "--output-dir", od_ok, remote_tokens..., ok_script,
                    ]
                )
                ride_fail = _kit_cli_cmd(
                    [
                        "ride", "-y", "--no-spi-check",
                        "--output-dir", od_fail, remote_tokens..., fail_script,
                    ]
                )
                runner = joinpath(dir, "ride_remote_tty.sh")
                exports = join(
                    ["export $(sh_quote(k))=$(sh_quote(v))" for (k, v) in sort!(collect(pairs(tty_env)))],
                    "\n",
                )
                write(
                    runner,
                    """
                    #!/bin/sh
                    unset DISTSSHKIT_QUIET
                    unset DISTSSHKIT_PROGRESS
                    unset DISTSSHKIT_VERBOSE
                    unset DISTSSHKIT_CLI_SUBCOMMAND_DONE
                    unset DIST_SSH_KIT_CLI_INCLUDE
                    export JULIA_LOAD_PATH=$(sh_quote(_child_load_path()))
                    unset JULIA_PROJECT
                    $exports
                    unset NO_COLOR
                    $(argv_line(ride_ok))
                    echo "___OK_EXIT_\$?___"
                    echo '___SPLIT___'
                    $(argv_line(ride_fail))
                    echo "___FAIL_EXIT_\$?___"
                    """,
                )
                chmod(runner, 0o755)
                t0 = time()
                pty = _tty_capture_script(
                    runner;
                    typescript = joinpath(dir, "ride_remote_typescript.txt"),
                    hang_s = 600.0,
                )
                elapsed = time() - t0
                @info "e2e ride remote progress_tty script child wall" elapsed
                parts = split(pty, "___SPLIT___")
                @test length(parts) == 2
                ok_tty = length(parts) == 2 ? parts[1] : ""
                fail_tty = length(parts) == 2 ? parts[2] : ""
                ok_plain = _tty_strip_ansi(ok_tty)
                fail_plain = _tty_strip_ansi(fail_tty)
                ok_m = match(r"___OK_EXIT_(\d+)___", ok_plain)
                fail_m = match(r"___FAIL_EXIT_(\d+)___", fail_plain)
                @test ok_m !== nothing && ok_m.captures[1] == "0"
                @test fail_m !== nothing && fail_m.captures[1] != "0"
                @test occursin("DISTSSHKIT_RIDE_REMOTE_OK", ok_plain)
                @test !occursin("Script: ", ok_plain)
                @test any(
                    l -> occursin("DISTSSHKIT_RIDE_REMOTE_OK", l) && !_tty_bar_line(l),
                    _tty_lines(ok_tty),
                )
                @test !occursin(
                    r"[━╺⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][^\n]*DISTSSHKIT_RIDE_REMOTE_OK",
                    ok_tty,
                )
                _assert_tty_progress_payload(ok_tty)
                rec = _assert_kit_progress_done(od_ok; kind = :ride)
                @test rec.kind === :ride && rec.ok === true
                kr_ok = DistSSHRun.kit_result_from_dir(od_ok)
                @test kr_ok !== nothing
                kr_ok === nothing && error("expected kit.result for remote ride success")
                @test kr_ok.kind === :ride
                @test kr_ok.ok === true
                @test kr_ok.exit_code == 0
                @test kr_ok.log_dir === nothing
                rd_ok = kr_ok.run_dir
                if rd_ok === nothing
                    side = joinpath(od_ok, "kit.run_dir")
                    @test isfile(side)
                    rd_ok = isfile(side) ? strip(read(side, String)) : ""
                end
                @test !isempty(rd_ok)
                raw_ok = DistSSHRun.read_kit_run_toml(rd_ok)
                @test raw_ok isa AbstractDict
                raw_ok isa AbstractDict && begin
                    @test get(raw_ok, "kind", nothing) == "ride"
                    @test !haskey(raw_ok, "log_dir")
                end
                @test occursin("DISTSSHKIT_RIDE_REMOTE_BOOM", fail_plain)
                @test any(
                    l -> occursin("DISTSSHKIT_RIDE_REMOTE_BOOM", l) && !_tty_bar_line(l),
                    _tty_lines(fail_tty),
                )
                @test !occursin(
                    r"[━╺⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][^\n]*DISTSSHKIT_RIDE_REMOTE_BOOM",
                    fail_tty,
                )
                _assert_tty_progress_payload(fail_tty)
                kr_fail = DistSSHRun.kit_result_from_dir(od_fail)
                @test kr_fail !== nothing
                kr_fail === nothing && error("expected kit.result for remote ride failure")
                @test kr_fail.kind === :ride
                @test kr_fail.ok === false
                @test kr_fail.exit_code != 0
                _assert_ssh_e2e_api_ok(
                    suite, "ride_remote_tty", true, "pty ok/fail captured",
                )
            end
        end

        @testset "go pi_echo both remotes" begin
            _e2e_announce("go pi_echo both remotes")
            proc, out = _run_kit_go(;
                script = pi_echo,
                hosts = remote_tokens,
                script_args = ["--n", "32"],
                project_root = proj,
                go_flags = ["-y"],
                extra_env = merge(_e2e_base_env(), Dict("DISTSSHKIT_QUIET" => "0")),
            )
            _assert_ssh_e2e_ok(suite, "go_pi_echo", proc, out; project = proj, kit = :go)
            @test occursin(hosts[1], out)
            @test occursin(hosts[2], out)
            @test count(r"π ≈", out) >= 2
            go_echo_batch = _ssh_e2e_latest_go_batch(proj)
            @test go_echo_batch !== nothing
            go_echo_batch === nothing && error("expected go batch for pi_echo")
            _assert_kit_progress_done(go_echo_batch; kind = :go)
        end

        @testset "go pi_file both remotes + collect" begin
            _e2e_announce("go pi_file both remotes + collect")
            # Queue always sets job_id. The mark is `-L` on the remote, not `--eval`.
            job_id = "e2e-go-1"
            proc, out = _run_kit_go(;
                script = pi_file,
                hosts = remote_tokens,
                script_args = ["--n", "32"],
                project_root = proj,
                go_flags = ["-y"],
                extra_env = merge(
                    _e2e_base_env(),
                    Dict(
                        "DISTSSHKIT_QUIET" => "0",
                        "DISTSSHKIT_JOB_ID" => job_id,
                    ),
                ),
            )
            _assert_ssh_e2e_ok(suite, "go_pi_file", proc, out; project = proj, kit = :go)
            batch = _ssh_e2e_latest_go_batch(proj)
            @test batch !== nothing
            batch === nothing && error("expected go batch for pi_file")
            _assert_kit_progress_done(batch; kind = :go)
            mark = DistSSHRun.kit_job_pkill_pattern(job_id)
            for host in hosts
                slot = joinpath(batch, host)
                results = joinpath(slot, "pi_results.txt")
                mark_path = joinpath(slot, mark)
                @test isdir(slot)
                @test isfile(results)
                isfile(results) && @test occursin("pi=", read(results, String))
                @test isfile(mark_path)
                isfile(mark_path) && @test strip(read(mark_path, String)) ==
                    DistSSHRun.kit_job_mark_comment(job_id)
            end
        end

        @testset "go pi_file with --output-dir" begin
            _e2e_announce("go pi_file with --output-dir")
            custom = joinpath(proj, "go_cli_output")
            isdir(custom) && rm(custom; recursive = true)
            proc, out = _run_kit_go(;
                script = pi_file,
                hosts = remote_tokens,
                script_args = ["--n", "32"],
                project_root = proj,
                go_flags = ["-y", "--output-dir", custom],
                extra_env = merge(_e2e_base_env(), Dict("DISTSSHKIT_QUIET" => "0")),
            )
            _assert_ssh_e2e_ok(suite, "go_pi_file_output_dir", proc, out; project = proj, kit = :go)
            for host in hosts
                slot = joinpath(custom, host)
                @test isdir(slot)
                @test isfile(joinpath(slot, "pi_results.txt"))
                @test occursin("pi=", read(joinpath(slot, "pi_results.txt"), String))
            end
        end

        @testset "setup ship-tree then go --snapshot empty remote" begin
            _e2e_announce("setup ship-tree then go --snapshot empty remote")
            oneshot = _ssh_e2e_go_rsync_remote_root()
            oneshot_env = _ssh_e2e_env(; remote_project = oneshot)
            try
                proc, out = _run_kit_setup(;
                    setup_args = ["delete", "--deploy-root", oneshot, "--confirm-path", oneshot, setup_hosts...],
                    project_root = proj,
                    extra_env = oneshot_env,
                )
                _assert_ssh_e2e_ok(suite, "go_rsync_empty_delete", proc, out; project = proj, kit = :setup)
                for host in hosts
                    p, ssh_out = _ssh_e2e_ssh(host, "test ! -e $(oneshot)/Project.toml")
                    _assert_proc_ok(p, ssh_out; label = "go snapshot empty $(host) gone")
                end
                _ssh_e2e_ensure_remote_root!(hosts, oneshot)

                proc, out = _run_kit_setup(;
                    setup_args = ["ship-tree", "--deploy-root", oneshot, setup_hosts...],
                    project_root = proj,
                    extra_env = oneshot_env,
                )
                _assert_ssh_e2e_ok(suite, "go_snapshot_empty_ship", proc, out; project = proj, kit = :setup)
                p_src, src_out = _ssh_e2e_ssh(hosts[1], "ls -1d $(oneshot)/runs/*/src 2>/dev/null | tail -n 1")
                _assert_proc_ok(p_src, src_out; label = "oneshot ship src leaf")
                snap_id = basename(dirname(strip(src_out)))
                @test !isempty(snap_id)
                proc, out = _run_kit_setup(;
                    setup_args = [
                        "instantiate", "--deploy-root", oneshot, "--snapshot", snap_id,
                        setup_hosts...,
                    ],
                    project_root = proj,
                    extra_env = oneshot_env,
                )
                _assert_ssh_e2e_ok(suite, "go_snapshot_empty_instantiate", proc, out; project = proj, kit = :setup)

                proc, out = _run_kit_go(;
                    script = pi_echo,
                    hosts = remote_tokens,
                    script_args = ["--n", "32"],
                    project_root = proj,
                    go_flags = ["-y", "--snapshot", snap_id],
                    extra_env = merge(oneshot_env, Dict("DISTSSHKIT_QUIET" => "0")),
                )
                _assert_ssh_e2e_ok(suite, "go_snapshot_empty", proc, out; project = proj, kit = :go)
                @test occursin(hosts[1], out)
                @test occursin(hosts[2], out)
                @test count(r"π ≈", out) >= 2
                for host in hosts
                    p, ssh_out = _run_subprocess(
                        Cmd(
                            [
                                "ssh", "-F", g.ssh_config, host,
                                "test -n \"\$(ls -d $(oneshot)/runs/*/src/Project.toml 2>/dev/null)\"",
                            ]
                        )
                    )
                    _assert_proc_ok(p, ssh_out; label = "go snapshot $(host) Project.toml")
                end
            finally
                proc, out = _run_kit_setup(;
                    setup_args = ["delete", "--deploy-root", oneshot, "--confirm-path", oneshot, setup_hosts...],
                    project_root = proj,
                    extra_env = oneshot_env,
                )
                _assert_ssh_e2e_ok(
                    suite, "go_rsync_empty_cleanup", proc, out;
                    project = proj, kit = :setup,
                )
            end
        end

        # `~/…` remote root: setup + drive still run. square_file CSV is local.
        @testset "drive square_file collect with tilde remote root" begin
            _e2e_announce("drive square_file collect with tilde remote root")
            tilde_root = _ssh_e2e_tilde_remote_root()
            tilde_env = _ssh_e2e_env(; remote_project = tilde_root)
            square_file = joinpath(proj, "demos", "with_kit", "square_file.jl")
            out_dir = joinpath(proj, "demos", "with_kit", "output")
            isdir(out_dir) && rm(out_dir; recursive = true)
            out_csv = joinpath(out_dir, "square_results.csv")

            proc, out = _run_kit_setup(;
                setup_args = ["delete", "--deploy-root", tilde_root, "--confirm-path", tilde_root, setup_hosts...],
                project_root = proj,
                extra_env = tilde_env,
            )
            _assert_ssh_e2e_ok(suite, "tilde_delete", proc, out; project = proj, kit = :setup)
            _ssh_e2e_ensure_remote_root!(hosts, tilde_root)

            proc, out = _run_kit_setup(;
                setup_args = ["ship-tree", "--deploy-root", tilde_root, setup_hosts...],
                project_root = proj,
                extra_env = tilde_env,
            )
            _assert_ssh_e2e_ok(suite, "tilde_rsync", proc, out; project = proj, kit = :setup)

            proc, out = _run_kit_setup(;
                setup_args = ["instantiate", "--deploy-root", tilde_root, setup_hosts...],
                project_root = proj,
                extra_env = tilde_env,
            )
            _assert_ssh_e2e_ok(suite, "tilde_instantiate", proc, out; project = proj, kit = :setup)

            proc, out = _run_kit_drive(;
                script = square_file,
                host_root = proj,
                parent_workers = 0,
                child_hosts = remote_tokens,
                script_args = ["--n", "4"],
                drive_flags = ["-y", "-q"],
                extra_env = tilde_env,
            )
            _assert_ssh_e2e_ok(suite, "tilde_drive_square_file", proc, out)
            @test isfile(out_csv)
            @test occursin("param,result", read(out_csv, String))
        end

        # Julian API path (same remotes): setup! → go! / pipeline!
        @testset "Julian API setup! + go!/pipeline!" begin
            _e2e_announce("Julian API setup! + go!/pipeline!")
            withenv(_e2e_base_env()...) do
                session = KitSession(
                    project = proj,
                    workers = remote_tokens,
                    remote = remote_root,
                    yes = true,
                    quiet = true,
                )
                deleted = setup!(
                    session, :delete;
                    confirm_path = Dict(h => remote_root for h in session.hosts),
                )
                _ssh_e2e_ensure_remote_root!(hosts, remote_root)
                rest = setup!(session, :ship_tree, :instantiate)
                _assert_ssh_e2e_api_ok(
                    suite,
                    "api_setup",
                    deleted.ok && rest.ok,
                    "hosts=$(length(deleted.hosts))",
                )
                @test deleted.ok && rest.ok
                @test !deleted.cancelled && !rest.cancelled
                @test length(deleted.hosts) == length(hosts)
                @test all(h -> h.ok, deleted.hosts)
                @test all(h -> h.ok, rest.hosts)

                go_out = joinpath(proj, "go_api_output")
                isdir(go_out) && rm(go_out; recursive = true)
                go_res = go!(
                    pi_file,
                    remote_tokens[1];
                    project = proj,
                    remote = remote_root,
                    args = ["--n", "16"],
                    yes = true,
                    quiet = true,
                    julia = "auto",
                    output_dir = go_out,
                )
                _assert_ssh_e2e_api_ok(suite, "api_go", go_res.ok)
                @test go_res.ok
                @test go_res.output_dir == DistSSHRun.canonical_local_path(go_out)
                go_txt = joinpath(go_res.output_dir, hosts[1], "pi_results.txt")
                @test isfile(go_txt)
                @test occursin("pi=", read(go_txt, String))

                worker_script = joinpath(proj, "worker_file.jl")
                worker_out = joinpath(proj, "output")
                isdir(worker_out) && rm(worker_out; recursive = true)
                pipe_res = pipeline!(
                    worker_script,
                    remote_tokens[2];
                    project = proj,
                    remote = remote_root,
                    collect = true,
                    enable_log = false,
                    yes = true,
                    quiet = true,
                    julia = "auto",
                )
                _assert_ssh_e2e_api_ok(suite, "api_pipeline", pipe_res.ok)
                @test pipe_res.ok
                worker_txts = filter(
                    f -> startswith(basename(f), "worker_"),
                    isdir(worker_out) ? readdir(worker_out; join = true) : String[],
                )
                @test !isempty(worker_txts)
                @test any(f -> occursin("DISTSSHKIT_E2E_WORKER_FILE", read(f, String)), worker_txts)
            end
        end

        # #144: in-process `drive!` tears down its remote workers per call
        # (not only at Julia exit). Two calls in this one process must each
        # see `nw=2` — a leak from the first would surface as `nw=4` in the
        # second. `pipeline!` above already did one in-process remote drive;
        # these are the reentrant calls that guard the regression over SSH.
        @testset "in-process drive! is reentrant (no worker leak)" begin
            _e2e_announce("in-process drive! is reentrant (no worker leak)")
            withenv(_e2e_base_env()...) do
                for call in 1:2
                    # `pipeline!` above leaves `DISTRIBUTED_OUTPUT_DIR` on the
                    # project `output/`, which now has files. This call does
                    # not pass `output_dir`.
                    delete!(ENV, "DISTRIBUTED_OUTPUT_DIR")
                    out = mktemp() do out_path, out_io
                        res = redirect_stdout(out_io) do
                            drive!(
                                smoke,
                                remote_tokens;
                                project = proj,
                                remote = remote_root,
                                julia = "auto",
                                verbosity = :verbose,
                                yes = true,
                            )
                        end
                        flush(out_io)
                        @test res.ok
                        @test res.exit_code == 0
                        @test Set(h.host for h in res.hosts) == Set(hosts)
                        @test all(h -> h.ok, res.hosts)
                        read(out_path, String)
                    end
                    _assert_ssh_e2e_api_ok(
                        suite,
                        "drive_reentrant_call$(call)",
                        occursin("DISTSSHKIT_RUNNER_SMOKE_OK nw=2", out),
                        "call=$(call)",
                    )
                    @test occursin("DISTSSHKIT_RUNNER_SMOKE_OK nw=2", out)
                    @test nworkers() == 1
                end
            end
        end

        # #148: SIGKILL the detached master after heartbeat is *running*
        # (`--worker` appears at addprocs, monitors start much later). atexit
        # cannot help. The ssh child may keep the tunnel, so reap is the
        # shortened deadline. Silent-stall scheduling is unit-tested.
        @testset "detached drive kill reaps remote workers" begin
            _e2e_announce("detached drive kill reaps remote workers")
            sleep_script = joinpath(proj, "sleep.jl")
            host = hosts[1]
            log_dir = joinpath(suite.logs, "heartbeat-drive")
            mkpath(log_dir)
            # Detached drive skips global pkill; drop leftovers so pgrep is ours.
            _ssh_e2e_ssh(host, "pkill -f 'julia.*--worker' || true")
            hb_env = merge(
                _e2e_base_env(), Dict(
                    "DISTRIBUTED_HEARTBEAT_INTERVAL_SEC" => "1",
                    "DISTRIBUTED_HEARTBEAT_DEADLINE_SEC" => "5",
                    "DISTRIBUTED_INIT_DELAY_SEC" => "0",
                )
            )
            kp = withenv(hb_env...) do
                DistSSHRun.execute!(
                    :drive,
                    sleep_script,
                    ["child:$(host):1"];
                    project = proj,
                    remote = remote_root,
                    detached = true,
                    yes = true,
                    quiet = true,
                    enable_log = true,
                    log_dir = log_dir,
                )
            end
            function _hb_log_text()
                isdir(log_dir) || return ""
                buf = IOBuffer()
                for f in readdir(log_dir; join = true)
                    endswith(f, ".log") || continue
                    print(buf, read(f, String))
                end
                return String(take!(buf))
            end
            function _worker_pids()
                _, body = _ssh_e2e_ssh(host, "pgrep -f 'julia.*--worker' || true")
                return Int[parse(Int, s) for s in split(strip(body); keepempty = false)]
            end
            # A queue that lost its in-memory `KitProcess` (e.g. restarted
            # mid-job) falls back to `kit.pid` — assert it names this run's
            # real OS pid before using it below instead of `kp.process`.
            pid_path = joinpath(log_dir, "kit.pid")
            pid_ready = false
            t0p = time()
            while (time() - t0p) < 10
                isfile(pid_path) && (pid_ready = true; break)
                sleep(0.1)
            end
            _assert_ssh_e2e_api_ok(suite, "kit_pid_file", pid_ready, "path=$(pid_path)")
            @test pid_ready
            rec = pid_ready ? DistSSHRun._read_kit_pid_record(log_dir) : nothing
            detached_pid = rec === nothing ? -1 : rec.pid
            @test detached_pid == getpid(kp.process)

            ready = false
            t0 = time()
            # Intel weekly (2026-10-15) still logged "Loading packages on workers"
            # at 90s, with `--worker` pids already present. Monitors start after that load.
            while (time() - t0) < 240
                # Prefix is logged before `@everywhere`; the ✓ is after monitors start.
                if occursin("Starting heartbeat monitors... ✓", _hb_log_text())
                    ready = true
                    break
                end
                process_running(kp.process) || break
                sleep(0.5)
            end
            pids = _worker_pids()
            _assert_ssh_e2e_api_ok(
                suite,
                "heartbeat_ready",
                ready && !isempty(pids),
                "ready=$(ready) pids=$(pids) log=$(repr(_hb_log_text()[max(1, end - 400):end]))",
            )
            @test ready
            @test !isempty(pids)
            # Kill by the `kit.pid`-derived pid, not `kp.process` — the path a
            # queue without the original `KitProcess` handle would take.
            run(`kill -9 $(detached_pid)`)
            wait(kp.process)
            gone = false
            t1 = time()
            leftover = pids
            while (time() - t1) < 30
                live = Set(_worker_pids())
                leftover = Int[p for p in pids if p in live]
                if isempty(leftover)
                    gone = true
                    break
                end
                sleep(0.5)
            end
            _assert_ssh_e2e_api_ok(suite, "heartbeat_reap", gone, "leftover=$(leftover)")
            @test gone
        end

        # Detached SSH ride writes `kit.hosts`; `terminate!` SIGTERMs then
        # tagged `pkill` (never `julia.*--worker`). Parent-only ride is unit.
        @testset "detached ride terminate! reaps remote workers" begin
            _e2e_announce("detached ride terminate! reaps remote workers")
            ride_script = joinpath(proj, "ride_sleep.jl")
            host = hosts[1]
            _ssh_e2e_ssh(host, "pkill -f 'julia.*--worker' || true")
            kp = withenv(_e2e_base_env()...) do
                DistSSHRun.execute!(
                    :ride,
                    ride_script,
                    ["child:$(host):1"];
                    project = proj,
                    remote = remote_root,
                    detached = true,
                    yes = true,
                    quiet = true,
                    spi_check = false,
                    job_id = "e2e-ride-term",
                )
            end
            out = kp.output_dir
            @test out isa AbstractString
            hosts_path = joinpath(String(out), "kit.hosts")
            hosts_ready = false
            t0h = time()
            while (time() - t0h) < 90
                if isfile(hosts_path) && !isempty(strip(read(hosts_path, String)))
                    hosts_ready = true
                    break
                end
                process_running(kp.process) || break
                sleep(0.5)
            end
            listed = hosts_ready ? DistSSHRun._read_kit_hosts(String(out)) : String[]
            function _kit_snip(name)
                p = joinpath(String(out), name)
                isfile(p) || return ""
                text = strip(read(p, String))
                return last(text, min(length(text), 800))
            end
            err_snip = _kit_snip("kit.out")
            err_err = _kit_snip("kit.err")
            _assert_ssh_e2e_api_ok(
                suite,
                "ride_kit_hosts",
                hosts_ready && host in listed,
                "ready=$(hosts_ready) listed=$(listed) path=$(hosts_path) out=$(repr(err_snip)) err=$(repr(err_err))",
            )
            @test hosts_ready
            @test host in listed

            function _ride_worker_pids()
                _, body = _ssh_e2e_ssh(host, "pgrep -f 'julia.*--worker' || true")
                return Int[parse(Int, s) for s in split(strip(body); keepempty = false)]
            end
            workers_ready = false
            t0w = time()
            while (time() - t0w) < 60
                if !isempty(_ride_worker_pids())
                    workers_ready = true
                    break
                end
                process_running(kp.process) || break
                sleep(0.5)
            end
            pids = _ride_worker_pids()
            _assert_ssh_e2e_api_ok(
                suite,
                "ride_workers_up",
                workers_ready && !isempty(pids),
                "pids=$(pids)",
            )
            @test workers_ready
            @test !isempty(pids)

            result = with_logger(_DropTaggedPkillWarn(current_logger())) do
                DistSSHRun.terminate!(kp; grace = 15)
            end
            @test result isa DistSSHRun.KitRunResult
            @test result.kind === :ride
            @test !process_running(kp.process)

            gone = false
            leftover = pids
            t1 = time()
            while (time() - t1) < 30
                live = Set(_ride_worker_pids())
                leftover = Int[p for p in pids if p in live]
                if isempty(leftover)
                    gone = true
                    break
                end
                sleep(0.5)
            end
            _assert_ssh_e2e_api_ok(suite, "ride_terminate_reap", gone, "leftover=$(leftover)")
            @test gone
        end

        @testset "setup ship-tree onto an existing root" begin
            _e2e_announce("setup ship-tree onto an existing root")
            proc, out = _run_kit_setup(;
                setup_args = ["ship-tree", "--deploy-root", remote_root, setup_hosts[1]],
                project_root = proj,
                extra_env = merge(_e2e_base_env(), Dict("DISTSSHKIT_QUIET" => "0")),
            )
            _assert_ssh_e2e_ok(suite, "setup_ship_tree_again", proc, out; project = proj, kit = :setup)
        end

        @testset "inter-child SSH (child-1 → child-2)" begin
            _e2e_announce("inter-child SSH (child-1 → child-2)")
            cmd = Cmd(
                [
                    "ssh", "-F", g.ssh_config, hosts[1],
                    "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 " *
                        "dev@child-2 'echo inter-ok'",
                ]
            )
            proc, out = _run_subprocess(cmd)
            _assert_ssh_e2e_ok(suite, "inter_child_ssh", proc, out)
            @test occursin("inter-ok", out)
        end

        # Git path (separate remote root): bare on child-1 → clone → check hash → sync → --require-git.
        @testset "git clone + sync + require-git" begin
            _e2e_announce("git clone + sync + require-git")
            git_root = _ssh_e2e_git_remote_root()
            git_env = _ssh_e2e_env(; remote_project = git_root)
            seed = withenv(git_env...) do
                _ssh_e2e_seed_git_origin!(proj)
            end
            @test seed !== nothing
            seed === nothing && error("expected git origin seed")

            proc, out = _run_kit_setup(;
                setup_args = [
                    "delete", "--deploy-root", git_root, "--confirm-path", git_root, setup_hosts...,
                ],
                project_root = proj,
                extra_env = git_env,
            )
            _assert_ssh_e2e_ok(suite, "git_delete", proc, out; project = proj, kit = :setup)

            proc, out = _run_kit_setup(;
                setup_args = [
                    "clone",
                    "--repo", seed.origin_workers,
                    "--deploy-root", git_root,
                    setup_hosts...,
                ],
                project_root = proj,
                extra_env = git_env,
            )
            _assert_ssh_e2e_ok(suite, "git_clone", proc, out; project = proj, kit = :setup)

            proc, out = _run_kit_setup(;
                setup_args = [
                    "instantiate", "--deploy-root", git_root, setup_hosts...,
                ],
                project_root = proj,
                extra_env = git_env,
            )
            _assert_ssh_e2e_ok(suite, "git_instantiate", proc, out; project = proj, kit = :setup)

            proc, out = _run_kit_setup(;
                setup_args = ["check", "--deploy-root", git_root, setup_hosts...],
                project_root = proj,
                extra_env = merge(git_env, Dict("DISTSSHKIT_QUIET" => "0")),
            )
            _assert_ssh_e2e_ok(suite, "git_check", proc, out; project = proj, kit = :setup)
            local_before = DistSSHRun.get_local_git_hash(proj; short = 12)
            @test local_before isa String
            local_before isa String || error("expected local git hash")
            @test occursin(local_before, out)

            bumped = withenv(git_env...) do
                _ssh_e2e_git_bump_commit!(proj)
            end
            @test bumped isa String
            @test bumped != local_before

            proc, out = _run_kit_drive(;
                script = joinpath(proj, "smoke.jl"),
                host_root = proj,
                parent_workers = 0,
                child_hosts = remote_tokens,
                drive_flags = ["-y", "-q", "--require-git"],
                extra_env = merge(git_env, Dict("DISTSSHKIT_QUIET" => "0")),
            )
            _ssh_e2e_record!(
                suite, "git_require_git_mismatch", proc, out;
                expect_ok = false, project = proj,
            )
            @test proc.exitcode != 0
            @test occursin("mismatch", lowercase(out)) || occursin("could not be verified", lowercase(out))

            proc, out = _run_kit_setup(;
                setup_args = ["sync", "--deploy-root", git_root, setup_hosts...],
                project_root = proj,
                extra_env = merge(git_env, Dict("DISTSSHKIT_QUIET" => "0")),
            )
            _assert_ssh_e2e_ok(suite, "git_sync", proc, out; project = proj, kit = :setup)

            proc, out = _run_kit_setup(;
                setup_args = ["check", "--deploy-root", git_root, setup_hosts...],
                project_root = proj,
                extra_env = merge(git_env, Dict("DISTSSHKIT_QUIET" => "0")),
            )
            _assert_ssh_e2e_ok(suite, "git_check_after_sync", proc, out; project = proj, kit = :setup)
            bumped isa String || error("expected bumped git hash")
            @test occursin(bumped, out)

            # drive --require-git must pass when remotes have matching .git/
            proc, out = _run_kit_drive(;
                script = joinpath(proj, "smoke.jl"),
                host_root = proj,
                parent_workers = 0,
                child_hosts = remote_tokens,
                drive_flags = ["-y", "-q", "--require-git"],
                extra_env = git_env,
            )
            _assert_ssh_e2e_ok(suite, "git_drive_require_git", proc, out)
            @test occursin("DISTSSHKIT_RUNNER_SMOKE_OK", out)

            pulled = withenv(git_env...) do
                p = _ssh_e2e_git_bump_commit!(proj; message = "e2e-pull")
                _ssh_e2e_git_push!(proj)
                p
            end
            @test pulled isa String
            marker = read(joinpath(proj, "e2e_sync_marker.txt"), String)

            proc, out = _run_kit_setup(;
                setup_args = ["pull", "--deploy-root", git_root, setup_hosts...],
                project_root = proj,
                extra_env = merge(git_env, Dict("DISTSSHKIT_QUIET" => "0")),
            )
            _assert_ssh_e2e_ok(suite, "git_pull", proc, out; project = proj, kit = :setup)
            for host in hosts
                p, body = withenv(git_env...) do
                    _e2e_run_on_host(
                        host,
                        ["-e", "print(read($(repr(joinpath(git_root, "e2e_sync_marker.txt"))), String))"],
                    )
                end
                _assert_proc_ok(p, body; label = "pull marker $(host)")
                @test body == marker
            end

            prev = strip(read(`git -C $proj rev-parse --abbrev-ref HEAD`, String))
            try
                run(pipeline(`git -C $proj checkout -q -b distsshkit-e2e-feature`; stdout = devnull, stderr = devnull))
                write(joinpath(proj, "e2e_feature.txt"), "feature\n")
                run(pipeline(`git -C $proj add e2e_feature.txt`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $proj -c commit.gpgsign=false commit -q -m feature`; stdout = devnull, stderr = devnull))
                withenv(git_env...) do
                    gssh = _docker_ssh_generated()
                    push_cmd = setenv(
                        `git -C $proj push -u origin HEAD:distsshkit-e2e-feature`,
                        Dict("GIT_SSH_COMMAND" => "ssh -F $(gssh.ssh_config) -o RequestTTY=no"),
                    )
                    proc_push, out_push = _run_subprocess(push_cmd)
                    _assert_proc_ok(proc_push, out_push; label = "push feature branch")
                end
                feature_sha = strip(read(`git -C $proj rev-parse HEAD`, String))
                proc, out = _run_kit_setup(;
                    setup_args = ["sync", "--deploy-root", git_root, setup_hosts...],
                    project_root = proj,
                    extra_env = merge(git_env, Dict("DISTSSHKIT_QUIET" => "0")),
                )
                _ssh_e2e_record!(suite, "git_sync_feature_detach", proc, out; expect_ok = true, project = proj, kit = :setup)
                @test proc.exitcode == 0
                @test occursin("Detached HEAD", out)
                @test !occursin("HEAD mismatch", out)
                @test !occursin("will be an error", out)
                for host in hosts
                    p, body = withenv(git_env...) do
                        _ssh_e2e_ssh(host, "git -C $(git_root) rev-parse HEAD")
                    end
                    _assert_proc_ok(p, body; label = "feature HEAD $(host)")
                    @test strip(body) == feature_sha
                    p, _ = withenv(git_env...) do
                        _ssh_e2e_ssh(host, "git -C $(git_root) symbolic-ref -q HEAD")
                    end
                    @test p.exitcode != 0
                    p, body = withenv(git_env...) do
                        _ssh_e2e_ssh(host, "cat $(git_root)/e2e_feature.txt")
                    end
                    _assert_proc_ok(p, body; label = "feature file $(host)")
                    @test strip(body) == "feature"
                end
            finally
                run(pipeline(`git -C $proj checkout -q $prev`; stdout = devnull, stderr = devnull))
                try
                    run(pipeline(`git -C $proj branch -D distsshkit-e2e-feature`; stdout = devnull, stderr = devnull))
                catch
                end
            end
        end

        @testset "setup ship-tree sends a gitignore negation" begin
            _e2e_announce("setup ship-tree sends a gitignore negation")
            neg_root = "/home/dev/distsshkit-e2e-negation"
            _with_tempdir() do app_path
                app = String(app_path)
                write(joinpath(app, "Project.toml"), "name = \"NegationApp\"\n")
                write(joinpath(app, "Manifest.toml"), "# lock\n")
                write(joinpath(app, ".gitignore"), "data/*\n!data/keep.txt\n")
                mkpath(joinpath(app, "data"))
                write(joinpath(app, "data", "a.dat"), "nope\n")
                write(joinpath(app, "data", "keep.txt"), "keep\n")
                run(pipeline(`git -C $app init -q`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $app config user.email "e2e@example.com"`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $app config user.name "e2e"`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $app add -A`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $app -c commit.gpgsign=false commit -q -m init`; stdout = devnull, stderr = devnull))
                neg_env = _ssh_e2e_env(; remote_project = neg_root)
                proc, out = _run_kit_setup(;
                    setup_args = [
                        "delete", "--deploy-root", neg_root, "--confirm-path", neg_root, setup_hosts...,
                    ],
                    project_root = app,
                    extra_env = neg_env,
                )
                _assert_ssh_e2e_ok(suite, "negation_delete", proc, out; project = app, kit = :setup)
                _ssh_e2e_ensure_remote_root!(hosts, neg_root)
                proc, out = _run_kit_setup(;
                    setup_args = ["ship-tree", "--deploy-root", neg_root, setup_hosts...],
                    project_root = app,
                    extra_env = neg_env,
                )
                _assert_ssh_e2e_ok(suite, "negation_rsync", proc, out; project = app, kit = :setup)
                for host in hosts
                    p, ssh_out = _ssh_e2e_ssh(host, "test -n \"\$(ls -d $(neg_root)/runs/*/src/data/keep.txt 2>/dev/null)\"")
                    _assert_proc_ok(p, ssh_out; label = "negation keep.txt $(host)")
                    p, ssh_out = _ssh_e2e_ssh(host, "test -z \"\$(ls -d $(neg_root)/runs/*/src/data/a.dat 2>/dev/null)\"")
                    _assert_proc_ok(p, ssh_out; label = "negation a.dat absent $(host)")
                end
            end
        end

        @testset "ship-tree path dep and external script" begin
            _e2e_announce("ship-tree path dep and external script")
            dep_root = "/home/dev/distsshkit-e2e-shipdep"
            _with_tempdir() do parent_path
                parent = String(parent_path)
                app = joinpath(parent, "app")
                bar = joinpath(parent, "Bar")
                mkpath(joinpath(app, "src"))
                mkpath(joinpath(bar, "src"))
                write(
                    joinpath(bar, "Project.toml"),
                    """
                    name = "Bar"
                    uuid = "22222222-2222-4222-8222-222222222222"
                    version = "0.1.0"
                    """,
                )
                write(
                    joinpath(bar, "src", "Bar.jl"),
                    "module Bar\ngreet() = \"from-bar\"\nend\n",
                )
                write(
                    joinpath(app, "Project.toml"),
                    """
                    name = "ShipE2E"
                    uuid = "11111111-1111-4111-8111-111111111111"
                    version = "0.1.0"

                    [deps]
                    Bar = "22222222-2222-4222-8222-222222222222"

                    [sources]
                    Bar = {path = "../Bar"}
                    """,
                )
                write(joinpath(app, "src", "ShipE2E.jl"), "module ShipE2E\nend\n")
                helper = joinpath(parent, "use_bar.jl")
                write(helper, "using Bar\nprint(Bar.greet())\n")
                depot = mktempdir()
                try
                    run(
                        setenv(
                            `$(Base.julia_cmd()) --project=$app -e 'using Pkg; Pkg.resolve()'`,
                            merge(ENV, Dict("JULIA_DEPOT_PATH" => depot)),
                        )
                    )
                finally
                    rm(depot; force = true, recursive = true)
                end
                dep_env = _ssh_e2e_env(; remote_project = dep_root)
                proc, out = _run_kit_setup(;
                    setup_args = [
                        "delete", "--deploy-root", dep_root, "--confirm-path", dep_root, setup_hosts...,
                    ],
                    project_root = app,
                    extra_env = dep_env,
                )
                _assert_ssh_e2e_ok(suite, "shipdep_delete", proc, out; project = app, kit = :setup)
                _ssh_e2e_ensure_remote_root!(hosts, dep_root)
                proc, out = _run_kit_setup(;
                    setup_args = [
                        "ship-tree", "--deploy-root", dep_root, "--extra-file", helper, setup_hosts...,
                    ],
                    project_root = app,
                    extra_env = dep_env,
                )
                _assert_ssh_e2e_ok(suite, "shipdep_ship", proc, out; project = app, kit = :setup)
                proc, out = _run_kit_setup(;
                    setup_args = ["instantiate", "--deploy-root", dep_root, setup_hosts...],
                    project_root = app,
                    extra_env = dep_env,
                )
                _assert_ssh_e2e_ok(suite, "shipdep_instantiate", proc, out; project = app, kit = :setup)
                for host in hosts
                    remote = """
                    leaf=\$(ls -1d $(dep_root)/runs/*/src/app | tail -n 1)
                    test -f "\$leaf/../Bar/src/Bar.jl"
                    \$HOME/.juliaup/bin/julia --startup-file=no --project="\$leaf" "\$leaf/_distsshrun_external/use_bar.jl"
                    """
                    p, ssh_out = _ssh_e2e_ssh(host, remote)
                    _assert_proc_ok(p, ssh_out; label = "path dep script $(host)")
                    @test strip(ssh_out) == "from-bar"
                end
            end
        end

        @testset "detached execute ships an outside script" begin
            _e2e_announce("detached execute ships an outside script")
            outside = joinpath(dirname(proj), "outside_marker.jl")
            write(outside, "println(\"OUTSIDE_SCRIPT_OK\")\n")
            outside_root = remote_root * "-outside"
            _ssh_e2e_ensure_remote_root!(hosts, outside_root)
            kp = withenv(_e2e_base_env()...) do
                DistSSHRun.execute!(
                    :go,
                    outside,
                    ["child:$(hosts[1]):1"];
                    project = proj,
                    remote = outside_root,
                    detached = true,
                    sync = :ship_tree,
                    yes = true,
                    quiet = true,
                )
            end
            result = wait(kp)
            _assert_ssh_e2e_api_ok(
                suite,
                "detached_outside_script",
                result.ok && result.exit_code == 0,
                "ok=$(result.ok) exit=$(result.exit_code) step=$(result.failed_step)",
            )
            @test result.ok
            @test result.exit_code == 0
            p, ssh_out = _ssh_e2e_ssh(
                hosts[1],
                "test -f \$(ls -1d $(outside_root)/runs/*/src/_distsshrun_external/outside_marker.jl | tail -n 1)",
            )
            _assert_proc_ok(p, ssh_out; label = "outside script shipped")
        end
    end
end
