# Precompile-time component fingerprint (schema 1).

const _SRC_FILES = (
    "DistSSHBase.jl",
    "ssh/paths.jl",
    "ssh/state_dir.jl",
    "messages/explain.jl",
    "argv/cursor.jl",
    "hosts/hosts.jl",
    "hosts/host_tokens.jl",
    "messages/cli_entry.jl",
    "ssh/sigint.jl",
    "messages/cli_exit.jl",
    "ssh/shell_status.jl",
    "ssh/budgets.jl",
    "messages/help.jl",
    "ssh/ssh.jl",
    "hosts/hostinfo.jl",
    "hosts/host_result.jl",
    "ssh/julia_where.jl",
    "procs/list.jl",
    "procs/reap.jl",
    "namespace.jl",
    "component_src.jl",
    "tool_require.jl",
)

const _COMPONENT_SRC_DIGEST = src_component_digest(@__DIR__, _SRC_FILES)

const COMPONENT_ID = (
    schema = 1,
    name = "DistSSHBase",
    uuid = Base.UUID("f0a69307-14e5-4272-8c28-20680d05bac8"),
    version = "0.2.0-DEV",
    digest = _COMPONENT_SRC_DIGEST,
)
