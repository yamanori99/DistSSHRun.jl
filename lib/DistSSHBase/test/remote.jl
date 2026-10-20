using Test

@testset "remote" begin
    @test DistSSHBase.ssh_addprocs_machine("dev@host1") == "dev@host1"
    @test DistSSHBase.ssh_addprocs_machine("  alice@h  ") == "alice@h"

    @test DistSSHBase.normalize_git_clone_url("https://github.com/org/App.jl.git") ==
        "git@github.com:org/App.jl.git"
    @test DistSSHBase.normalize_git_clone_url("git@github.com:org/App.jl.git") ==
        "git@github.com:org/App.jl.git"

    @test DistSSHBase.default_remote_project_path("/Users/z/GitHub/MyApp.jl") ==
        joinpath("~", "GitHub", "MyApp.jl")

    withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => nothing) do
        @test DistSSHBase.resolve_remote_project_root("/Users/z/GitHub/MyApp.jl") ==
            joinpath("~", "GitHub", "MyApp.jl")
    end
    withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/Volumes/shared/MyApp.jl") do
        @test DistSSHBase.resolve_remote_project_root("/Users/z/GitHub/MyApp.jl") ==
            "/Volumes/shared/MyApp.jl"
    end
    @test DistSSHBase.resolve_remote_project_root(
        "/Users/z/GitHub/MyApp.jl";
        cli_override = "~/work/MyApp.jl",
    ) == "~/work/MyApp.jl"
    @test DistSSHBase.remote_env_project_root("~/jobs/abc") == "~/jobs/abc"
    @test DistSSHBase.remote_env_project_root("~/.distsshkitqueue/jobs/x") ==
        "~/.distsshkitqueue/jobs/x"
    @test DistSSHBase.remote_env_project_root("/remote/App.jl") ==
        DistSSHBase.canonical_local_path("/remote/App.jl")
    withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/Volumes/shared/MyApp.jl") do
        @test DistSSHBase.resolve_remote_project_root(
            "/Users/z/GitHub/MyApp.jl";
            cli_override = "~/work/MyApp.jl",
        ) == "~/work/MyApp.jl"
    end

    @test DistSSHBase.local_dir_from_remote_mirror(
        "/Volumes/r/MyRepo/data/sweep/slug/20260101_120000",
        "/Volumes/r/MyRepo",
        "/Users/z/MyRepo",
    ) == joinpath("/Users/z/MyRepo", "data", "sweep", "slug", "20260101_120000") |> abspath
    @test_throws ArgumentError DistSSHBase.local_dir_from_remote_mirror(
        "~/r/MyRepo/data",
        "~/r/MyRepo",
        "/Users/z/MyRepo",
    )
    @test_throws ArgumentError DistSSHBase.local_dir_from_remote_mirror(
        "/Volumes/r/MyRepo/data",
        "~/r/MyRepo",
        "/Users/z/MyRepo",
    )

    @test DistSSHBase.resolve_remote_abs_path_on_host("host", "/data/MyRepo") == "/data/MyRepo"
    let missing = DistSSHBase._remote_abs_path_resolve_shell("~/distsshkit-e2e-tilde/output")
        @test occursin("printf", missing)
        @test !occursin("else exit 1; fi", missing)
    end
    let abs = DistSSHBase._remote_abs_path_resolve_shell("/data/MyRepo/output")
        @test occursin("else exit 1; fi", abs)
        @test !occursin("printf", abs)
    end
    let spaced = "~/Repo With Spaces/output"
        word = DistSSHBase._remote_shell_path_word(spaced)
        @test startswith(word, "~/")
        @test word != Base.shell_escape(spaced)
        @test occursin(Base.shell_escape("Repo With Spaces/output"), word)
        sh = DistSSHBase._remote_abs_path_resolve_shell(spaced)
        @test occursin("printf", sh)
        @test occursin(word, sh)
    end

    @test DistSSHBase.remote_layout_path(
        "/Users/z/MyRepo/data/out",
        "/Users/z/MyRepo",
    ) == joinpath("~", "z", "MyRepo", "data", "out")
    withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/Volumes/z/clone/MyRepo") do
        @test DistSSHBase.remote_layout_path(
            "/Users/z/MyRepo/data/sweep/x/ts",
            "/Users/z/MyRepo",
        ) == joinpath("/Volumes/z/clone/MyRepo", "data", "sweep", "x", "ts") |> abspath
    end
    withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => "~/work/MyRepo") do
        @test DistSSHBase.remote_layout_path(
            "/Users/z/MyRepo/demos/with_kit",
            "/Users/z/MyRepo",
        ) == joinpath("~/work/MyRepo", "demos", "with_kit")
    end
    @test DistSSHBase.remote_layout_path(
        "/Users/z/other/file",
        "/Users/z/MyRepo",
    ) == "/Users/z/other/file"

    @testset "ensure_remote_abs_path" begin
        @test DistSSHBase.ensure_remote_abs_path("host", "/home/dev/App") == "/home/dev/App"
        @test DistSSHBase.ensure_remote_abs_path("host", "") === nothing
        @test DistSSHBase.ensure_remote_abs_path("host", "   ") === nothing
    end

    @testset "resolve_host_path_abs" begin
        _with_tempdir() do tmp
            p = DistSSHBase.canonical_local_path(tmp)
            @test DistSSHBase.resolve_host_project_abs("parent", p) == p
            withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/Volumes/z/clone/MyRepo") do
                @test DistSSHBase.resolve_host_project_abs("host", p) == "/Volumes/z/clone/MyRepo"
            end
        end
    end

    withenv(
        "DISTRIBUTED_SSH_OPTS" => nothing,
        "DISTSSHKIT_WAIT_SSH_CONNECT" => nothing,
        "DISTSSHKIT_WAIT_PEER_SILENT" => nothing,
    ) do
        opts = DistSSHBase.build_ssh_opts()
        @test "-o" in opts
        @test "BatchMode=yes" in opts
        @test "RequestTTY=no" in opts
        @test "ConnectTimeout=10" in opts
        @test "ServerAliveInterval=60" in opts
        @test "ServerAliveCountMax=10" in opts
        @test DistSSHBase.ssh_opts() == String.(opts)
        tty = DistSSHBase.ssh_opts(; request_tty = true)
        @test !("RequestTTY=no" in tty)
        @test "BatchMode=yes" in tty
        @test DistSSHBase.build_ssh_opts(; request_tty = true) == tty
        @test DistSSHBase.ssh_opts(; request_tty = false) == DistSSHBase.ssh_opts()
    end
    withenv(
        "DISTRIBUTED_SSH_OPTS" => nothing,
        "DISTSSHKIT_WAIT_SSH_CONNECT" => "0.4",
        "DISTSSHKIT_WAIT_PEER_SILENT" => "0",
    ) do
        opts = DistSSHBase.build_ssh_opts()
        @test "ConnectTimeout=1" in opts
        @test "ServerAliveInterval=60" in opts
        @test "ServerAliveCountMax=10" in opts
    end
    withenv("DISTRIBUTED_SSH_OPTS" => "-o Foo=bar -o Baz=qux") do
        @test DistSSHBase.build_ssh_opts() == ["-o", "Foo=bar", "-o", "Baz=qux"]
        @test DistSSHBase.ssh_opts() == ["-o", "Foo=bar", "-o", "Baz=qux"]
        @test DistSSHBase.ssh_opts(; request_tty = true) == ["-o", "Foo=bar", "-o", "Baz=qux"]
    end
    withenv("DISTRIBUTED_SSH_OPTS" => "-F /tmp/ssh_config") do
        @test DistSSHBase.ssh_opts() == ["-F", "/tmp/ssh_config"]
        @test DistSSHBase.ssh_opts(; request_tty = true) == ["-F", "/tmp/ssh_config"]
    end

    _with_tempdir() do tmp
        @test DistSSHBase.clone_url_from_local_origin(tmp) === nothing
        Sys.which("git") === nothing && return
        run(Cmd(["git", "-C", tmp, "init", "-q"]))
        run(Cmd(["git", "-C", tmp, "remote", "add", "origin", "https://github.com/org/App.jl.git"]))
        @test DistSSHBase.clone_url_from_local_origin(tmp) == "git@github.com:org/App.jl.git"
    end

    @test DistSSHBase.parse_julia_version("julia version 1.13.1") == v"1.13.1"
    @test DistSSHBase.parse_julia_version("julia version 1.9.0-DEV") == v"1.9.0"
    @test DistSSHBase.parse_julia_version("julia version 1.13.0-beta1") == v"1.13.0"
    @test DistSSHBase.parse_julia_version("") === nothing
    @test DistSSHBase.parse_julia_version("not julia at all") === nothing

    @testset "remote_julia_candidates" begin
        darwin = DistSSHBase.remote_julia_candidates("Darwin")
        @test darwin[1] == raw"$HOME/.juliaup/bin/julia"
        @test "/opt/homebrew/bin/julia" in darwin
        @test "/usr/local/bin/julia" in darwin
        linux = DistSSHBase.remote_julia_candidates("Linux")
        @test linux[1] == raw"$HOME/.juliaup/bin/julia"
        @test "/usr/bin/julia" in linux
        @test !("/opt/homebrew/bin/julia" in linux)
    end

    @testset "resolve_controller_julia" begin
        p = DistSSHBase.resolve_controller_julia("auto")
        @test isabspath(p)
        @test isfile(p)
        @test DistSSHBase.resolve_controller_julia(nothing) == p
        @test DistSSHBase.resolve_controller_julia(p) == p
        @test_throws ArgumentError DistSSHBase.resolve_controller_julia("/no/such/julia")
    end

    @testset "_remote_shell_path_word" begin
        @test DistSSHBase._remote_shell_path_word("~/Repo With Spaces/output") ==
            "~/" * Base.shell_escape("Repo With Spaces/output")
        spaced = "/opt/Julia 1.12/bin/julia"
        @test DistSSHBase._remote_shell_path_word(spaced) == Base.shell_escape(spaced)
        meta = "/tmp/j;rm -rf /"
        @test DistSSHBase._remote_shell_path_word(meta) == Base.shell_escape(meta)
        @test DistSSHBase._remote_shell_path_word(meta) != meta
    end

    @testset "detect_julia_path cache" begin
        empty!(DistSSHBase._DETECT_JULIA_PATH_CACHE)
        try
            @test DistSSHBase.detect_julia_path("") === nothing
            @test !haskey(DistSSHBase._DETECT_JULIA_PATH_CACHE, "")
            DistSSHBase._DETECT_JULIA_PATH_CACHE["cache-hit.host"] = "/opt/julia"
            @test DistSSHBase.detect_julia_path("cache-hit.host") == "/opt/julia"
            DistSSHBase.clear_detect_julia_path_cache!("cache-hit.host")
            @test !haskey(DistSSHBase._DETECT_JULIA_PATH_CACHE, "cache-hit.host")
            DistSSHBase._DETECT_JULIA_PATH_CACHE["a"] = "/a"
            DistSSHBase._DETECT_JULIA_PATH_CACHE["b"] = "/b"
            DistSSHBase.clear_detect_julia_path_cache!()
            @test isempty(DistSSHBase._DETECT_JULIA_PATH_CACHE)
        finally
            empty!(DistSSHBase._DETECT_JULIA_PATH_CACHE)
        end
    end

    @testset "run_on_host remote sh" begin
        sh = DistSSHBase._run_on_host_remote_sh(["-e", "1"]; detect = true)
        @test occursin("uname -s", sh)
        @test occursin("exec", sh)
        @test occursin(raw"$HOME/.juliaup/bin/julia", sh)
        @test occursin("/opt/homebrew/bin/julia", sh)
        @test occursin("-e", sh)
        @test DistSSHBase._remote_argv_sh(["-e", "exit(3)"]) == "'-e' 'exit(3)'"
        @test DistSSHBase._remote_sh_quote("a'b") == raw"'a'\''b'"
        expl = DistSSHBase._run_on_host_remote_sh(["--version"]; julia = "/opt/julia", detect = false)
        @test occursin("/opt/julia", expl)
        @test occursin("exec", expl)
        @test !occursin("uname", expl)
        @test_throws ArgumentError DistSSHBase._run_on_host_remote_sh(
            String[]; detect = false, julia = nothing,
        )
        @test_throws ArgumentError DistSSHBase.run_on_host("", ["--version"])
        withenv("PATH" => "/nonexistent-distsshkit-path") do
            @test_throws ["ArgumentError:", "ssh not found in PATH"] DistSSHBase.run_on_host(
                "no-such-host.invalid", ["--version"],
            )
            @test_throws ["ArgumentError:", "OpenSSH"] DistSSHBase._host_tool_exe("ssh")
            @test_throws ["ArgumentError:", "rsync not found"] DistSSHBase._host_tool_exe("rsync")
            @test_throws ["ArgumentError:", "git not found"] DistSSHBase._host_tool_exe("git")
            @test_throws ["ArgumentError:", "scp not found"] DistSSHBase._host_tool_exe("scp")
        end
    end
end
