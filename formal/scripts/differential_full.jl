#!/usr/bin/env julia
# POSIX `posix_quote` round-trip: Julia vs dash/bash/zsh vs Lean `sh_posix_eval`.
using Random: MersenneTwister, rand
using DistSSHBase: posix_quote

const FORMAL = dirname(@__DIR__)  # formal/
const REPO = dirname(FORMAL)
const LEAN_EXE = joinpath(FORMAL, ".lake/build/bin/sh_posix_eval")
const AUDIT = joinpath(FORMAL, "diff", "posix_quote_audit.log")
const SUMMARY = joinpath(FORMAL, "diff", "posix_quote_summary.txt")

function ensure_lean_exe!()
    isfile(LEAN_EXE) && return
    run(setenv(`lake build sh_posix_eval`; dir=FORMAL))
    isfile(LEAN_EXE) || error("missing $LEAN_EXE after lake build")
end

function run_lean(s::String)::String
    cp(LEAN_EXE, "/tmp/sh_posix_eval"; force=true)
    chmod("/tmp/sh_posix_eval", 0o755)
    got = read(`/tmp/sh_posix_eval $s`, String)
    return chop(got; head=0, tail=endswith(got, "\n") ? 1 : 0)
end

function shell_roundtrip(s::String, q::String, argv::Vector{String})::Tuple{Bool,String}
    script = "printf %s " * q
    cmd = Cmd(vcat(argv, ["-c", script]))
    try
        got = strip(read(cmd, String), ['\0'])
        return (got == s, got)
    catch e
        return (false, "__ERROR__:" * sprint(showerror, e))
    end
end

function gen_corpus(n::Int)::Vector{String}
    rng = MersenneTwister(0x505350)
    charset = ['a':'z'...; 'A':'Z'...; '0':'9'...; '\''; '\\'; '!'; '~'; '\$'; ' '; '\t'; '\n';
               'あ'; '語'; '😀']
    out = String["", "'", "\\", "a'b", "\n\t", "あいう", repeat('\'', 30)]
    while length(out) < n
        push!(out, String(rand(rng, charset, rand(rng, 0:min(90, n - length(out))))))
        rand(rng) < 0.12 && push!(out, String(repeat('\'', rand(rng, 1:24))))
    end
    v = unique!(out)
    v[1:min(n, length(v))]
end

function main()
    mkpath(joinpath(FORMAL, "diff"))
    PATH = joinpath(homedir(), ".elan", "bin") * ":" * get(ENV, "PATH", "")
    ENV["PATH"] = PATH
    ensure_lean_exe!()
    shells = Tuple{String,Vector{String}}[
        ("dash", ["/bin/dash"]),
        ("bash_posix", ["/bin/bash", "--posix"]),
        ("zsh_f", ["/usr/bin/zsh", "-f"]),
    ]
    corpus = gen_corpus(2100)
    counts = Dict{String,Int}()
    mism = 0
    lean_mism = 0
    skipped = 0

    open(AUDIT, "w") do io
        for s in corpus
            if occursin('\0', s)
                skipped += 1
                println(io, "skip reason=nul in=$(repr(s))")
                continue
            end
            q = posix_quote(s)
            try
                got = run_lean(s)
                ok = got == s
                ok || (lean_mism += 1)
                counts["lean"] = get(counts, "lean", 0) + 1
                println(io, "shell=lean ok=$ok in=$(repr(s)) q=$(repr(q)) got=$(repr(got))")
            catch e
                lean_mism += 1
                counts["lean"] = get(counts, "lean", 0) + 1
                println(io, "shell=lean ok=false in=$(repr(s)) error=$(repr(sprint(showerror,e)))")
            end
            for (name, argv) in shells
                ok, got = shell_roundtrip(s, q, argv)
                counts[name] = get(counts, name, 0) + 1
                ok || (mism += 1)
                println(io, "shell=$name ok=$ok in=$(repr(s)) q=$(repr(q)) got=$(repr(got))")
            end
            script = "emulate -L sh; printf %s " * q
            try
                got = strip(read(Cmd(["/usr/bin/zsh", "-f", "-c", script]), String), ['\0'])
                ok = got == s
                counts["zsh_emulate_sh"] = get(counts, "zsh_emulate_sh", 0) + 1
                ok || (mism += 1)
                println(io, "shell=zsh_emulate_sh ok=$ok in=$(repr(s)) q=$(repr(q)) got=$(repr(got))")
            catch e
                counts["zsh_emulate_sh"] = get(counts, "zsh_emulate_sh", 0) + 1
                mism += 1
                println(io, "shell=zsh_emulate_sh ok=false in=$(repr(s)) error=$(repr(sprint(showerror,e)))")
            end
        end
    end

    open(SUMMARY, "w") do io
        println(io, "corpus_target=2100 corpus_unique=$(length(corpus)) skipped_nul=$skipped")
        println(io, "shell_mismatches=$mism lean_mismatches=$lean_mism")
        for (k, v) in sort(collect(counts))
            println(io, "$k=$v")
        end
    end
    mism + lean_mism > 0 && exit(1)
    println("differential ok: $(length(corpus)) inputs, lean_mism=$lean_mism shell_mism=$mism skipped=$skipped")
end

main()