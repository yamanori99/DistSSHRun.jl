"""Console and progress names Queue prints with. Help and exits stay in `messages/`."""
module CLI

mutable struct KitProgressItem
    label::String
    status::Symbol
    tick::Int
end

mutable struct KitProgressState
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
    items::Vector{KitProgressItem}
    drawn::Int
    cursor_hidden::Bool
    job_id::Union{Nothing, String}
    released::Bool
end

function KitProgressState(
        title::AbstractString,
        steps::Int,
        done::Int,
        label::AbstractString;
        kind::Symbol = :unknown,
        job_id::Union{Nothing, AbstractString} = nothing,
    )
    return KitProgressState(
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
        KitProgressItem[],
        0,
        false,
        job_id === nothing ? nothing : String(job_id),
        false,
    )
end

const KIT_PROGRESS = Ref{Union{Nothing, KitProgressState}}(nothing)
const KIT_PROGRESS_SUSPEND = Ref(0)

function print_warn end
function kit_println end
function print_header end
function writeln_field end
function kit_confirm end
function kit_progress_done! end
function kit_progress_latest end

public KitProgressState
public KIT_PROGRESS
public KIT_PROGRESS_SUSPEND
public print_warn
public kit_println
public print_header
public writeln_field
public kit_confirm
public kit_progress_done!
public kit_progress_latest

end
