using Test
using DistSSHRun

@testset "topology and bind rules" begin
    @testset "resolved topology" begin
        @test DistSSHRun.resolved_topology("master_worker") == :master_worker
        @test DistSSHRun.resolved_topology("master-worker") == :master_worker
        @test DistSSHRun.topology_for_launch(; topology_setting = "auto", unsafe_all_to_all = false) ==
            :master_worker
        @test DistSSHRun.topology_for_launch(;
            topology_setting = "auto",
            unsafe_all_to_all = true,
        ) == :all_to_all
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
            @test occursin("non-loopback", msg)
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
            @test occursin("empty bind", msg)
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
