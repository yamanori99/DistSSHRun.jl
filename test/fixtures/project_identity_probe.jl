using SHA, TOML
function env_sha256(path)
    isfile(path) || return ""
    return lowercase(bytes2hex(sha256(read(path))))
end
proj = Base.active_project()
man = ""
man_sha = ""
pf = ""
proj_sha = ""
if proj !== nothing
    pf = String(proj)
    man0 = try
        Base.project_file_manifest_path(pf)
    catch
        nothing
    end
    if man0 isa AbstractString && isfile(man0)
        man = String(man0)
        man_sha = env_sha256(man)
    end
    proj_sha = env_sha256(pf)
end
img_path = try
    string(realpath(unsafe_string(Base.JLOptions().image_file)))
catch
    unsafe_string(Base.JLOptions().image_file)
end
ext = Sys.isapple() ? ".dylib" : Sys.iswindows() ? ".dll" : ".so"
def_img = joinpath(Sys.BINDIR, "..", "lib", "julia", "sys" * ext)
img_default = try
    realpath(unsafe_string(Base.JLOptions().image_file)) == realpath(def_img)
catch
    false
end
print("version=", string(VERSION), '\n')
print("commit=", string(Base.GIT_VERSION_INFO.commit), '\n')
print("sysimage=", img_path, '\n')
print("sysimage.default=", img_default, '\n')
print("manifest=", man, '\n')
print("manifest.sha256=", man_sha, '\n')
print("project=", pf, '\n')
print("project.sha256=", proj_sha, '\n')
if !isempty(man) && isfile(man)
    raw = TOML.parsefile(man)
    if raw isa AbstractDict
        deps = get(raw, "deps", nothing)
        if deps isa AbstractDict
            for name in ("DistSSHRun", "DistSSHKit", "DistSSHQueue", "DistSSHBase")
                entry = get(deps, name, nothing)
                tab = if entry isa AbstractDict
                    entry
                elseif entry isa AbstractVector && !isempty(entry) && first(entry) isa AbstractDict
                    first(entry)
                else
                    nothing
                end
                tab === nothing && continue
                v = get(tab, "version", nothing)
                v isa AbstractString && print("pkg.", name, '=', String(v), '\n')
            end
        end
    end
end