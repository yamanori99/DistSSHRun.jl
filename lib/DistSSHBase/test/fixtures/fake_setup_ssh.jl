#!/usr/bin/env julia
# Test double for setup `ssh HOST REMOTE_SCRIPT` (see DISTSSHKIT_TEST_SSH).
#
# Per-host state under DISTSSHKIT_TEST_STATE_ROOT/<slot>/tree represents the
# remote destination directory (missing / empty / nonempty).

function _dest_status(tree::AbstractString)::String
    if !isdir(tree)
        return "MISSING"
    end
    return isempty(readdir(tree)) ? "EMPTY" : "NONEMPTY"
end

function main()
    host = length(ARGS) >= 1 ? ARGS[1] : ""
    script = length(ARGS) >= 2 ? ARGS[2] : ""
    state_root = get(ENV, "DISTSSHKIT_TEST_STATE_ROOT", "")
    if isempty(state_root)
        exit(1)
    end
    slot = if get(ENV, "DISTSSHKIT_TEST_SHARED_TREE", "") == "1"
        "shared"
    else
        replace(host, r"[@:/]" => "_")
    end
    dir = joinpath(state_root, slot)
    tree = joinpath(dir, "tree")

    # Force every probe/op to fail (preflight + delete/clone).
    if get(ENV, "DISTSSHKIT_TEST_SSH_FAIL", "") == "1"
        println(stderr, "Permission denied (publickey).")
        exit(255)
    end

    logp = get(ENV, "DISTSSHKIT_TEST_SSH_LOG", "")
    if !isempty(logp)
        open(logp, "a") do io
            println(io, script)
        end
    end

    # POSIX login-shell probe (`case`) and a separate `echo $SHELL`. A pass
    # prints the marker anywhere in stdout. This double is a POSIX shell.
    if occursin("__DSR_POSIX_OK_", script) && occursin("case x in x)", script)
        m = match(r"__DSR_POSIX_OK_[0-9a-fA-F]+__", script)
        m === nothing && exit(1)
        println(m.match)
        exit(0)
    end
    if strip(script) == "echo \$SHELL"
        println("/bin/sh")
        exit(0)
    end

    if occursin("DISTSSHKIT_REMOTE_HOME", script)
        println(get(ENV, "DISTSSHKIT_TEST_REMOTE_HOME", "/home/distsshkit"))
        exit(0)
    end

    if occursin("uname -s", script)
        if get(ENV, "DISTSSHKIT_TEST_UNAME_FAIL", "") == "1"
            exit(1)
        end
        u = get(ENV, "DISTSSHKIT_TEST_UNAME", "")
        isempty(u) || println(u)
        exit(0)
    end

    if occursin("command -v julia", script) || occursin("which julia", script)
        w = get(ENV, "DISTSSHKIT_TEST_JULIA_WHICH", "")
        isempty(w) || println(w)
        exit(0)
    end

    # detect_julia_path candidates: `test -x PATH && echo PATH`
    if occursin("test -x", script) && occursin("&& echo", script)
        if occursin("juliaup", script) && get(ENV, "DISTSSHKIT_TEST_NO_JULIAUP", "") == "1"
            exit(1)
        end
        m = match(r"&&\s*echo\s+(.+)$", script)
        if m !== nothing
            cap = m.captures[1]
            cap isa AbstractString || exit(1)
            println(strip(String(cap)))
            exit(0)
        end
        exit(1)
    end

    # setup --juliaup remote body (home install and/or Homebrew candidates)
    if (occursin(".juliaup/bin/juliaup", script) || occursin("/opt/homebrew/bin/juliaup", script)) &&
            occursin("status 2>/dev/null", script) &&
            get(ENV, "DISTSSHKIT_TEST_JULIAUP_ALREADY", "") == "1"
        println("already")
        exit(0)
    end
    if (occursin(".juliaup/bin/juliaup", script) || occursin("/opt/homebrew/bin/juliaup", script)) &&
            occursin("\"\$JU\" update", script) &&
            !occursin("echo already", script)
        if get(ENV, "DISTSSHKIT_TEST_NO_JULIAUP", "") == "1"
            println(stderr, "juliaup not found (tried: \$HOME/.juliaup/bin/juliaup, /opt/homebrew/bin/juliaup)")
            exit(127)
        end
        println("ok")
        exit(0)
    end
    if (occursin(".juliaup/bin/juliaup", script) || occursin("/opt/homebrew/bin/juliaup", script)) &&
            (occursin(" add ", script) || occursin("default", script))
        if get(ENV, "DISTSSHKIT_TEST_NO_JULIAUP", "") == "1"
            println(stderr, "juliaup not found (tried: \$HOME/.juliaup/bin/juliaup, /opt/homebrew/bin/juliaup)")
            exit(127)
        end
        println("ok")
        exit(0)
    end

    if occursin("--version", script)
        ver = strip(get(ENV, "DISTSSHKIT_TEST_JULIA_VERSION", ""))
        println(isempty(ver) ? "julia version $VERSION" : ver)
        exit(0)
    end

    if occursin("DISTSSHKIT_POOL", script)
        println("DISTSSHKIT_POOL")
        println(get(ENV, "DISTSSHKIT_TEST_POOL_MEM", "17179869184"))
        println(get(ENV, "DISTSSHKIT_TEST_POOL_NCPU", "4"))
        exit(0)
    end

    if occursin("DISTSSHKIT_DEST_STATUS", script)
        println("DISTSSHKIT_DEST_STATUS")
        println(_dest_status(tree))
        exit(0)
    end

    # setup SSH preflight (`echo ok`) and similar probes
    if strip(script) == "echo ok" || strip(script) == "true"
        println("ok")
        exit(0)
    end

    if startswith(strip(script), "test -d")
        if isdir(tree)
            println("ok")
            exit(0)
        end
        exit(1)
    end

    if occursin("test -f", script) && occursin("Project.toml", script)
        if isfile(joinpath(tree, "Project.toml"))
            println("ok")
        end
        exit(0)
    end

    # Quoted argv is `'git' … 'pull'`, which does not contain the substring `git pull`.
    if occursin("git pull", script) ||
            (occursin("'pull'", script) && occursin("hooksPath=/dev/null", script))
        if get(ENV, "DISTSSHKIT_TEST_GIT_PULL_FAIL", "") == "1"
            println("fatal: not a git repository")
            exit(1)
        end
        exit(0)
    end

    if occursin("rev-parse", script)
        if get(ENV, "DISTSSHKIT_TEST_GIT_REV_PARSE_FAIL", "") == "1"
            println(stderr, "fatal: not a git repository")
            exit(1)
        end
        head = get(ENV, "DISTSSHKIT_TEST_GIT_HEAD", "")
        isempty(head) && exit(1)
        println(head)
        occursin("--abbrev-ref", script) && println(get(ENV, "DISTSSHKIT_TEST_GIT_BRANCH", "main"))
        exit(0)
    end

    if occursin("touch ", script)
        m = match(r"touch\s+(\S+)", script)
        if m !== nothing
            cap = m.captures[1]
            cap isa AbstractString || exit(1)
            name = basename(strip(String(cap), ['\'', '"']))
            mkpath(tree)
            touch(joinpath(tree, name))
        end
        exit(0)
    end

    if occursin("rm -f ", script)
        m = match(r"rm -f\s+(\S+)", script)
        if m !== nothing
            cap = m.captures[1]
            if cap isa AbstractString
                name = basename(strip(String(cap), ['\'', '"']))
                rm(joinpath(tree, name); force = true)
            end
        end
        exit(0)
    end

    if occursin("mkdir -p", script)
        if get(ENV, "DISTSSHKIT_TEST_MKDIR_FAIL", "") == "1"
            exit(1)
        end
        mkpath(tree)
        exit(0)
    end

    if occursin("git clone", script)
        if get(ENV, "DISTSSHKIT_TEST_GIT_CLONE_FAIL", "") == "1"
            println("fatal: repository not found")
            exit(1)
        end
        st = _dest_status(tree)
        if st == "NONEMPTY"
            println("fatal: destination path already exists and is not an empty directory.")
            exit(1)
        end
        mkpath(tree)
        mkpath(joinpath(tree, ".git"))
        println("Cloning into 'tree'...")
        exit(0)
    end

    if occursin("DISTSSHKIT_PRUNE_KIT_LEAVES", script)
        older = nothing
        m_old = match(r"older=([^\n]+)", script)
        if m_old !== nothing
            cap = m_old.captures[1]
            if cap isa AbstractString
                s = strip(cap, ['\'', '"'])
                n = tryparse(Int, s)
                n === nothing || (older = n)
            end
        end
        id = nothing
        m_id = match(r"\nid=([^\n]+)", script)
        if m_id !== nothing
            cap = m_id.captures[1]
            if cap isa AbstractString
                s = strip(cap, ['\'', '"'])
                isempty(s) || (id = s)
            end
        end
        if isdir(tree)
            for (dir, _, _) in walkdir(tree)
                basename(dir) == ".distsshkit" || continue
                go = joinpath(dir, "go")
                if isdir(go)
                    for child in readdir(go; join = true)
                        isdir(child) || continue
                        (id === nothing || occursin(id, basename(child))) || continue
                        if older !== nothing && (time() - mtime(child)) < older * 86400
                            continue
                        end
                        rm(child; recursive = true, force = true)
                    end
                end
                if id === nothing
                    for kind in ("drive", "setup")
                        p = joinpath(dir, kind)
                        isdir(p) || continue
                        if older !== nothing && (time() - mtime(p)) < older * 86400
                            continue
                        end
                        rm(p; recursive = true, force = true)
                    end
                end
            end
        end
        exit(0)
    end

    if occursin("rm -rf", script)
        if isdir(dir)
            rm(dir; recursive = true, force = true)
        end
        exit(0)
    end

    # Job `setup --runtest` (`using Pkg; Pkg.test()`). Preflight is `echo ok`.
    if occursin("Pkg.test()", script)
        if get(ENV, "DISTSSHKIT_TEST_PKG_TEST_FAIL", "") == "1"
            println(stderr, "Test Failed")
            exit(1)
        end
        exit(0)
    end

    if occursin("find ", script) && occursin("-type f", script)
        if get(ENV, "DISTSSHKIT_TEST_FIND_FAIL", "") == "1"
            println(stderr, "find: failed")
            exit(1)
        end
        if occursin("-newer", script)
            mnew = match(r"-newer\s+(\S+)", script)
            capn = mnew === nothing ? nothing : mnew.captures[1]
            if capn isa AbstractString
                name = basename(strip(String(capn), ['\'', '"']))
                if !isfile(joinpath(tree, name))
                    println(stderr, "find: No such file or directory")
                    exit(1)
                end
            end
        end
        m = match(r"find\s+(\S+)\s+-type", script)
        cap = m === nothing ? nothing : m.captures[1]
        find_root = cap === nothing ? tree : String(cap)
        find_root = strip(find_root, ['\'', '"'])
        nul = occursin("-print0", script)
        name_excl = nothing
        mname = match(r"!\s*-name\s+(\S+)", script)
        if mname !== nothing && mname.captures[1] isa AbstractString
            pat = strip(String(mname.captures[1]), ['\'', '"'])
            # find -name glob: `*` → any chars in the basename.
            name_excl = Regex("^" * replace(pat, "*" => ".*") * "\$")
        end
        if isdir(tree)
            for (root, _, files) in walkdir(tree)
                for f in files
                    name_excl !== nothing && occursin(name_excl, f) && continue
                    rel = relpath(joinpath(root, f), tree)
                    path = joinpath(find_root, rel)
                    if nul
                        print(path)
                        print('\0')
                    else
                        println(path)
                    end
                end
            end
        end
        exit(0)
    end

    if strip(script) == "cd -P ~ && pwd -P"
        println(get(ENV, "DISTSSHKIT_TEST_REMOTE_HOME", "/home/distsshkit"))
        exit(0)
    end

    if occursin("elif test -e", script) && occursin("printf", script)
        home = get(ENV, "DISTSSHKIT_TEST_REMOTE_HOME", "/home/distsshkit")
        println(home * "/ship-root")
        exit(0)
    end

    if occursin("Sys.BINDIR", script)
        w = get(ENV, "DISTSSHKIT_TEST_JULIA_WHICH", "")
        println(isempty(w) ? "/usr/bin/julia" : w)
        exit(0)
    end

    if occursin("Tar.extract", script)
        mkpath(tree)
        exit(0)
    end

    return exit(0)
end

main()
