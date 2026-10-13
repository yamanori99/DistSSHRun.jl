using Test

@testset "pkg env" begin
    _with_tempdir() do root
        lab = joinpath(root, "lab")
        member = joinpath(lab, "experiments", "run1")
        mkpath(member)
        write(
            joinpath(lab, "Project.toml"), """
            name = "Lab"
            [workspace]
            projects = ["experiments/run1"]
            """
        )
        write(joinpath(lab, "Manifest.toml"), "# lock\n")
        write(
            joinpath(member, "Project.toml"), """
            name = "Run1"
            [deps]
            """
        )
        env = DistSSHBase.resolve_pkg_env(member)
        @test env.project_dir == DistSSHBase.canonical_local_path(member)
        @test env.env_dir == DistSSHBase.canonical_local_path(lab)
        @test env.manifest == DistSSHBase.canonical_local_path(joinpath(lab, "Manifest.toml"))
        @test DistSSHBase.julia_project_rel(env) == joinpath("experiments", "run1")
        withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => nothing) do
            deploy = DistSSHBase.remote_deploy_root(member)
            julia_remote = DistSSHBase.resolve_remote_project_root(member)
            @test deploy == joinpath("~", basename(dirname(lab)), "lab")
            @test julia_remote == joinpath(deploy, "experiments", "run1")
            if Sys.which("git") !== nothing
                run(pipeline(`git -C $lab init -q`; stdout = devnull, stderr = devnull))
                @test DistSSHBase.remote_git_clone_dest(member) == deploy
            end
        end

        solo = joinpath(root, "solo")
        mkpath(solo)
        write(joinpath(solo, "Project.toml"), "name = \"Solo\"\n[deps]\n")
        bare = DistSSHBase.resolve_pkg_env(solo)
        @test bare.manifest === nothing
        @test bare.env_dir == bare.project_dir
        @test DistSSHBase.julia_project_rel(bare) == "."

        ver = joinpath(root, "ver")
        mkpath(ver)
        write(joinpath(ver, "Project.toml"), "name = \"Ver\"\n[deps]\n")
        write(joinpath(ver, "Manifest-v$(VERSION.major).$(VERSION.minor).toml"), "# v\n")
        versioned = DistSSHBase.resolve_pkg_env(ver)
        @test versioned.manifest == DistSSHBase.canonical_local_path(
            joinpath(ver, "Manifest-v$(VERSION.major).$(VERSION.minor).toml"),
        )
        @test versioned.env_dir == versioned.project_dir

        if Sys.which("git") !== nothing
            nest = joinpath(root, "nest")
            nest_member = joinpath(nest, "lab", "experiments", "run1")
            mkpath(nest_member)
            write(
                joinpath(nest, "lab", "Project.toml"),
                "name = \"NestLab\"\n[workspace]\nprojects = [\"experiments/run1\"]\n",
            )
            write(joinpath(nest, "lab", "Manifest.toml"), "# lock\n")
            write(joinpath(nest_member, "Project.toml"), "name = \"NestRun\"\n[deps]\n")
            run(pipeline(`git -C $nest init -q`; stdout = devnull, stderr = devnull))
            withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => nothing) do
                nest_deploy = DistSSHBase.remote_deploy_root(nest_member)
                @test DistSSHBase.remote_git_clone_dest(nest_member) == dirname(nest_deploy)
                @test DistSSHBase.remote_delete_root(nest_member) == dirname(nest_deploy)
                @test DistSSHBase.remote_delete_root(nest_member; cli_override = "/srv/job") == "/srv/job"
                @test_throws ArgumentError DistSSHBase.remote_git_clone_dest(
                    nest_member; cli_override = "/srv/job",
                )
            end
        end
    end
end
