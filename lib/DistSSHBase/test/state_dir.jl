using Test

@testset "state_dir" begin
  @test DistSSHBase.LOCAL_STATE_DIR == ".distssh"
  @test DistSSHBase.LEGACY_LOCAL_STATE_DIR == ".distsshkit"
  @test DistSSHBase.local_state_dir_names() == (".distssh", ".distsshkit")

  _with_tempdir() do tmp
    write(joinpath(tmp, "Project.toml"), "name = \"T\"\n")
    new_setup = joinpath(tmp, ".distssh", "setup", "x.log")
    mkpath(dirname(new_setup))
    write(new_setup, "new\n")
  end

  _with_tempdir() do tmp
    leg = joinpath(tmp, ".distsshkit", "inputs.toml")
    mkpath(dirname(leg))
    write(leg, "legacy\n")
    got = DistSSHBase.resolve_local_state_item(tmp, "inputs.toml")
    @test got == leg
    @test DistSSHBase.resolve_local_state_dir_name(tmp) == ".distsshkit"
  end

  _with_tempdir() do tmp
    @test DistSSHBase.resolve_local_state_item(tmp, "go", "batch") ==
      joinpath(tmp, ".distssh", "go", "batch")
    @test DistSSHBase.local_state_write_root(tmp) == joinpath(tmp, ".distssh")
    @test DistSSHBase.local_state_relpath("runs", "go") == joinpath(".distssh", "runs", "go")
    @test DistSSHBase.resolve_local_state_dir(tmp, :go) == joinpath(tmp, ".distssh", "go")
  end

  _with_tempdir() do tmp
    mkpath(joinpath(tmp, ".distsshkit", "cache", "sha256"))
    h = "a" ^ 64
    write(joinpath(tmp, ".distsshkit", "cache", "sha256", h), "blob")
    @test DistSSHBase.resolve_remote_cache_dir(tmp) ==
      joinpath(tmp, ".distsshkit", "cache", "sha256")
    @test DistSSHBase.remote_cache_dir(tmp) == joinpath(tmp, ".distssh", "cache", "sha256")
  end

  @test DistSSHBase.is_local_state_dir_name(".distssh")
  @test DistSSHBase.is_local_state_dir_name(".distsshkit")
  @test !DistSSHBase.is_local_state_dir_name(".git")
end
