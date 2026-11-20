using Test
using DistSSHRun

@testset "topology and bind rules" begin
    @testset "resolved topology" begin
        @test DistSSHRun.resolved_topology("master_worker") == :master_worker
        err = try
            DistSSHRun.resolved_topology("master-worker")
        catch ex
            ex
        end
        @test err isa ArgumentError
        msg = sprint(showerror, err)
        @test occursin("master-worker", msg)
        @test occursin("DISTSSH_TOPOLOGY=master_worker", msg)
        @test DistSSHRun.topology_for_launch(; topology_setting = "auto", unsafe_all_to_all = false) ==
            :master_worker
        @test DistSSHRun.topology_for_launch(;
            topology_setting = "auto",
            unsafe_all_to_all = true,
        ) == :master_worker
    end

    @testset "dry-run launch topology matches addprocs" begin
        port_msg =
            "bind \"127.0.0.1:9000\" is not an IPv4 address; checked: dotted-quad IPv4 literal (ports are not allowed); fix: bind = \"127.0.0.1\""
        for unsafe in (false, true)
            top = DistSSHRun.topology_for_launch(;
                topology_setting = "auto",
                unsafe_all_to_all = unsafe,
            )
            plan = DistSSHRun.validate_host_launch_plan(
                "h1",
                "127.0.0.1";
                unsafe_all_to_all = unsafe,
                topology_setting = "auto",
            )
            @test top == plan.topology == :master_worker
        end
        let cfg = DistSSHRun.resolve_run_job_config(;
                command = :drive,
                cli_dry_run = true,
                cli_unsafe_all_to_all = true,
            ),
                buf = IOBuffer()
            DistSSHRun.print_run_job_dry_plan!(
                buf,
                cfg;
                hosts = ["2*lab-a", "lab-b"],
                worker_tokens = ["2*lab-a", "lab-b"],
                project = pwd(),
            )
            txt = String(take!(buf))
            @test count("topology=master_worker", txt) == 2
            @test !occursin("topology=all_to_all", txt)
        end
        @test DistSSHRun.launch_bind_host_key("2*lab") == "lab"
        for host in ("lab", "lab-a", "alice@mac")
            let msg = try
                    DistSSHRun.validate_host_launch_plan(host, "127.0.0.1:9000")
                catch e
                    e isa ArgumentError ? e.msg : rethrow()
                end
                @test msg == port_msg
            end
        end
        bad = "127.0.0.1:9000"
        let msg = try
                DistSSHRun.validate_all_host_launch_plans!(
                    ["lab-a", "lab-b"],
                    Dict("lab-a" => bad, "lab-b" => bad),
                )
            catch e
                e isa ArgumentError ? e.msg : rethrow()
            end
            @test msg == port_msg
        end
    end

    @testset "happy path plan line" begin
        plan = DistSSHRun.validate_host_launch_plan(
            "h1",
            "127.0.0.1";
            unsafe_expose_port = false,
            unsafe_all_to_all = false,
            topology_setting = "auto",
        )
        @test plan.topology == :master_worker
        line = DistSSHRun.format_host_launch_plan_line(plan)
        @test occursin("bind=127.0.0.1", line)
        @test occursin("topology=master_worker", line)
        @test occursin("tunnel=true", line) || occursin("tunnel=false", line)
    end

    @testset "per-host bind override resolution" begin
        overrides = Dict("lab" => "10.0.0.5")
        @test DistSSHRun.resolved_bind_address("lab", overrides) == "10.0.0.5"
        @test DistSSHRun.resolved_bind_address("other", overrides) == "127.0.0.1"
    end

    @testset "rejected combinations carry fix hints" begin
        let err = try
                DistSSHRun.validate_host_launch_plan(
                    "h1",
                    "127.0.0.1";
                    tunnel = false,
                    unsafe_expose_port = false,
                    unsafe_all_to_all = false,
                )
            catch e
                e
            end
            @test err isa ArgumentError
            msg = sprint(showerror, err)
            @test occursin("h1", msg)
            @test occursin("tunnel", msg)
            @test occursin("Hint:", msg)
            @test occursin("--unsafe-expose-port", msg)
        end
        let err = try
                DistSSHRun.validate_host_launch_plan(
                    "h1",
                    "0.0.0.0";
                    tunnel = true,
                    unsafe_expose_port = false,
                )
            catch e
                e
            end
            @test err isa ArgumentError
            msg = sprint(showerror, err)
            @test occursin("0.0.0.0", msg)
            @test occursin("--unsafe-expose-port", msg)
        end
        let err = try
                DistSSHRun.validate_host_launch_plan(
                    "h1",
                    "";
                    tunnel = true,
                    unsafe_expose_port = true,
                )
            catch e
                e
            end
            @test err isa ArgumentError
            msg = sprint(showerror, err)
            @test occursin("bind is empty", msg)
        end
        let err = try
                DistSSHRun.topology_for_launch(;
                    topology_setting = "master_worker",
                    unsafe_all_to_all = true,
                )
            catch e
                e
            end
            @test err isa ArgumentError
            msg = sprint(showerror, err)
            @test occursin("unsafe_all_to_all", msg)
            @test occursin("auto", msg)
        end
    end

    @testset "ssh addprocs bind string" begin
        @test DistSSHRun.ssh_addprocs_machine_bind("user@lab", "10.0.0.1") ==
            DistSSHRun.ssh_addprocs_machine("user@lab") * " 10.0.0.1"
    end
end
