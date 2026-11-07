# Shared TTY (`script`) capture helpers for `:progress` assertions.
# Guard: JETLS may analyze this file both via support.jl and as an include leaf.

if !isdefined(Main, :_tty_strip_ansi)
    function _tty_strip_ansi(s::AbstractString)
        return replace(String(s), r"\e\[[0-9;?]*[A-Za-z]" => "")
    end

    function _tty_lines(s::AbstractString)
        # Log-style view: each `\r` redraw becomes its own line (CI look).
        return split(_tty_strip_ansi(replace(String(s), "\r" => "\n")), '\n')
    end

    function _tty_bar_line(line::AbstractString)
        return occursin("[K", line) ||
            occursin("━", line) ||
            occursin("╺", line) ||
            any(c -> occursin(c, line), "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
    end

    function _tty_spinner_bar_line(line::AbstractString)
        return any(c -> occursin(c, line), "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏") &&
            (occursin("━", line) || occursin("╺", line))
    end

    function _tty_payload_line(line::AbstractString)
        return occursin("✗", line) ||
            occursin("!", line) ||
            occursin("Prerequisites", line) ||
            occursin("complete", line) ||
            occursin("SSH preflight failed", line) ||
            occursin("exit", line)
    end

    function _tty_fail_or_warn_line(line::AbstractString)
        s = String(line)
        return startswith(s, "  ✗") || startswith(s, "  !") ||
            startswith(s, "  Prerequisites")
    end

    # Live TTY: `\r` returns to column 0; CSI K after that clears the row.
    # Snapshot after each erase / newline and track how many spinner bars
    # would be on screen at once (must stay ≤ 1).
    function _tty_live_spinner_bar_peak(raw::AbstractString)
        finished = String[]
        cur = Ref("")
        at_home = false
        peak = Ref(0)
        function note!()
            rows = _tty_strip_ansi.(
                isempty(cur[]) ? finished : vcat(finished, String[cur[]]),
            )
            peak[] = max(peak[], count(_tty_spinner_bar_line, rows))
            return nothing
        end
        i = firstindex(raw)
        while i <= lastindex(raw)
            ch = raw[i]
            if ch == '\r'
                at_home = true
                i = nextind(raw, i)
            elseif ch == '\n'
                push!(finished, cur[])
                cur[] = ""
                at_home = false
                note!()
                i = nextind(raw, i)
            elseif ch == '\e'
                j = nextind(raw, i)
                if j <= lastindex(raw) && raw[j] == '['
                    k = nextind(raw, j)
                    while k <= lastindex(raw) && !isletter(raw[k])
                        k = nextind(raw, k)
                    end
                    k <= lastindex(raw) || break
                    if raw[k] == 'K'
                        if at_home
                            cur[] = ""
                            at_home = false
                        end
                        note!()
                    end
                    i = nextind(raw, k)
                else
                    i = j
                end
            else
                if at_home
                    cur[] = ""
                    at_home = false
                end
                cur[] *= string(ch)
                i = nextind(raw, i)
            end
        end
        note!()
        return peak[]
    end

    # Assert payload lines are not glued to the bar and have no post-payload redraw.
    function _assert_tty_progress_payload(raw::AbstractString; hosts::Vector{String} = String[])
        lines = _tty_lines(raw)
        for line in lines
            if _tty_payload_line(line)
                @test !_tty_bar_line(line)
                @test !occursin("[K", line)
                @test !any(c -> occursin(c, line), "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
                @test !occursin("━", line)
            end
            if _tty_fail_or_warn_line(line)
                @test startswith(line, "  ")
            end
        end
        # No cursor-up bar redraw after the last payload line in the byte stream.
        payload_keys = ("✗", "!", "Prerequisites", "complete", "SSH preflight failed", "exit")
        last_payload = nothing
        for key in payload_keys
            at = findlast(key, raw)
            at === nothing && continue
            if last_payload === nothing || first(at) > first(last_payload)
                last_payload = at
            end
        end
        if last_payload !== nothing
            after = SubString(raw, nextind(raw, last(last_payload)))
            @test !occursin(r"\e\[[0-9]*A", after)
        end
        if length(hosts) > 1
            fail_lines = filter(l -> occursin("✗", l) && !_tty_bar_line(l), lines)
            for host in hosts
                @test any(l -> occursin(host, l), fail_lines)
            end
            # Host name only in the Time table is a failure (already covered by
            # requiring each host on a fail line above).
        end
        return nothing
    end
end
