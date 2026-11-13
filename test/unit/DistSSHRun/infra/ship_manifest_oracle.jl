using Test

# `pack_entry_paths` must match extracted tar paths (same pipeline as pack_tree).

function _extracted_tar_file_rels(dest::AbstractString)::Vector{String}
    out = String[]
    for (dir, _, files) in walkdir(dest)
        rel = replace(relpath(dir, dest), '\\' => '/')
        for name in files
            child = rel == "." ? name : rel * "/" * name
            push!(out, child)
        end
    end
    return sort!(out)
end

function _omit_for(project::AbstractString)
    return String[
        i.path for i in DistSSHRun._load_ship_inputs(DistSSHRun.canonical_local_path(project))
    ]
end

function _git_commit_q!(repo::AbstractString, msg::AbstractString)
    run(
        pipeline(
            `git -C $repo -c user.email=test@example.com -c user.name=Test -c commit.gpgsign=false commit -q -m $msg`;
            stdout = devnull,
            stderr = devnull,
        ),
    )
    return nothing
end

function _oracle_matches_tar!(project::AbstractString)
    omit = _omit_for(project)
    listed = DistSSHRun.DistSSHShip.pack_entry_paths(project; omit_project_rels = omit)
    pack = DistSSHRun._pack_project_tree(project)
    extracted = String[]
    try
        extract_dir = mktempdir()
        try
            DistSSHRun.Tar.extract(pack.tar_path, extract_dir)
            extracted = _extracted_tar_file_rels(extract_dir)
        finally
            rm(extract_dir; force = true, recursive = true)
        end
        @test extracted == listed
        man_rel = DistSSHRun.DistSSHShip._manifest_pack_anchor_rel(project; omit_project_rels = omit)
        @test (man_rel in listed) == (man_rel in extracted)
    finally
        rm(pack.directory; force = true, recursive = true)
    end
    return listed
end

@testset "pack_entry_paths oracle matches tar" begin
    @testset "git repository, tracked Manifest" begin
        if Sys.which("git") !== nothing
            _with_tempdir() do tmp
                write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
                write(
                    joinpath(tmp, "Manifest.toml"),
                    "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
                )
                run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $tmp add -A`; stdout = devnull, stderr = devnull))
                _git_commit_q!(tmp, "init")
                listed = _oracle_matches_tar!(tmp)
                @test "Manifest.toml" in listed
            end
        end
    end

    @testset "git repository, gitignored Manifest" begin
        if Sys.which("git") !== nothing
            _with_tempdir() do tmp
                write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
                write(
                    joinpath(tmp, "Manifest.toml"),
                    "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
                )
                write(joinpath(tmp, ".gitignore"), "Manifest.toml\n")
                run(pipeline(`git -C $tmp init -q`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $tmp add Project.toml .gitignore`;
                        stdout = devnull,
                        stderr = devnull,
                    ),
                )
                _git_commit_q!(tmp, "init")
                omit = _omit_for(tmp)
                @test_throws ArgumentError DistSSHRun.DistSSHShip.pack_entry_paths(
                    tmp; omit_project_rels = omit,
                )
                @test_throws ArgumentError DistSSHRun.pack_ship_tree(tmp)
            end
        end
    end

    @testset "no git, gitignored Manifest" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, "Manifest.toml"), "# lock\n")
            write(joinpath(tmp, ".gitignore"), "Manifest.toml\n")
            omit = _omit_for(tmp)
            @test_throws ArgumentError DistSSHRun.DistSSHShip.pack_entry_paths(
                tmp; omit_project_rels = omit,
            )
        end
    end

    @testset "negation pattern keeps Manifest" begin
        _with_tempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"App\"\n")
            write(joinpath(tmp, "Manifest.toml"), "# lock\n")
            write(joinpath(tmp, ".gitignore"), "Manifest.toml\n!Manifest.toml\n")
            listed = _oracle_matches_tar!(tmp)
            @test "Manifest.toml" in listed
        end
    end

    @testset "external Manifest path gitignored is refused at pack" begin
        _with_tempdir() do root
            ext = joinpath(root, "extapp")
            locks = joinpath(root, "locks")
            mkpath(ext)
            mkpath(locks)
            outside_manifest = joinpath(locks, "Manifest.toml")
            write(outside_manifest, "# lock\n")
            write(
                joinpath(ext, "Project.toml"),
                "name = \"Ext\"\nmanifest = \"../locks/Manifest.toml\"\n",
            )
            write(joinpath(locks, ".gitignore"), "Manifest.toml\n")
            @test_throws ArgumentError DistSSHRun.DistSSHShip.pack_entry_paths(ext)
            @test_throws ArgumentError DistSSHRun.pack_ship_tree(ext)
        end
    end

    @testset "workspace member: ship_send_list differs, oracle matches tar" begin
        _with_tempdir() do root
            lab = joinpath(root, "lab")
            member = joinpath(lab, "experiments", "run1")
            mkpath(member)
            write(
                joinpath(lab, "Project.toml"),
                """
                name = "Lab"
                [workspace]
                projects = ["experiments/run1"]
                """,
            )
            write(joinpath(lab, "Manifest.toml"), "# lock\n")
            write(joinpath(member, "Project.toml"), "name = \"Run1\"\n[deps]\n")
            tree_root = DistSSHRun._ship_tree_root(member)
            send_only = DistSSHRun.ship_send_list(tree_root)
            listed = _oracle_matches_tar!(member)
            @test "Manifest.toml" in listed
            @test !("Manifest.toml" in send_only)
            @test listed != send_only
        end
    end
end
