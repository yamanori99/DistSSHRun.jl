"""Console and progress names Queue prints with. Help and exits stay in `messages/`."""
module CLI

mutable struct ProgressItem
    label::String
    status::Symbol
    tick::Int
end

mutable struct ProgressState
    title::String
    steps::Int
    done::Int
    label::String
    kind::Symbol
    active::Bool
    t0::Float64
    tick::Int
    spinning::Bool
    spinner_task::Union{Task, Nothing}
    items::Vector{ProgressItem}
    drawn::Int
    cursor_hidden::Bool
    job_id::Union{Nothing, String}
    released::Bool
end

function ProgressState(
        title::AbstractString,
        steps::Int,
        done::Int,
        label::AbstractString;
        kind::Symbol = :unknown,
        job_id::Union{Nothing, AbstractString} = nothing,
    )
    return ProgressState(
        String(title),
        steps,
        done,
        String(label),
        kind,
        false,
        time(),
        0,
        false,
        nothing,
        ProgressItem[],
        0,
        false,
        job_id === nothing ? nothing : String(job_id),
        false,
    )
end

const CURRENT_PROGRESS = Ref{Union{Nothing, ProgressState}}(nothing)
const PROGRESS_SUSPEND = Ref(0)

function print_warn end
function cli_println end
function print_header end
function writeln_field end
function cli_confirm end
function progress_done! end
function progress_latest end

public ProgressState
public CURRENT_PROGRESS
public PROGRESS_SUSPEND
public print_warn
public cli_println
public print_header
public writeln_field
public cli_confirm
public progress_done!
public progress_latest

end
