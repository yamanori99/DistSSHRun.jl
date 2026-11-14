# Julia 1.12+ binding world-age warnings on stderr. Included from support.jl
# (runtests.jl, e2e.jl, unit tests) and analyzed as its own file by JETLS.

const _BINDING_WORLD_STDERR_MARKERS = (
    "Detected access to binding",
    "prior to its definition world",
)

function _binding_world_age_warning_text(text::AbstractString)::Union{Nothing, String}
    for pat in _BINDING_WORLD_STDERR_MARKERS
        occursin(pat, text) && return pat
    end
    return nothing
end

function _assert_no_binding_world_stderr!(rel::AbstractString, text::AbstractString)
    hit = _binding_world_age_warning_text(text)
    hit === nothing && return nothing
    error(
        "Julia binding world-age warning in test file $(rel): stderr contains $(repr(hit))",
    )
end