# method.jl
#
# Decoder for the method dump the ÄKTAprime sends just before a run starts
# (OPC 0x2007, content in 0x8008–0x8011, closed by 0x2008). The dump is a
# printer-formatted text report, escaped like all method text (methodstore.jl);
# decoded it reads
#   ** Method Settings
#   Method base        ,ml
#   Brkp Volume   Conc Flow  Frac   Buff Inj    Peak   Autozero Eventmark
#   ,1   ,0.0     ,0   ,0.5  ,0.0   ,8   ,Load  ,0     ,N       ,N
# It holds a "Method Settings" block of `name ,value` lines and a breakpoint
# table with the columns Brkp, Volume (mL), Conc (%B), Flow (mL/min), Frac (mL),
# Buff (buffer valve port), Inj (injection valve), Peak (mAU/min), Autozero and
# Eventmark. The first breakpoint (volume 0) is the state the run starts in.

struct MethodDump
    settings::Vector{Pair{String,String}}
    columns::Vector{String}
    breakpoints::Vector{Dict{String,String}}
end

# A method dump as the Akta sends it (escaped).
parse_method_dump(raw::AbstractVector{UInt8})::MethodDump = parse_method_text(unescape_method_text(raw))

# Method text as stored in a PrimeMeth_NNN.txt file.
function parse_method_text(bytes::AbstractVector{UInt8})::MethodDump
    settings = Pair{String,String}[]
    columns = String[]
    breakpoints = Dict{String,String}[]
    for line in split(String(copy(bytes)), r"\r\n|\r|\n")
        line = rstrip(line)
        (isempty(strip(line)) || startswith(line, '*')) && continue   # rules and headings
        if startswith(line, "Brkp")
            columns = split(line)
        elseif startswith(line, ',')
            # Each value is prefixed by ','; padding before it is optional ("99999.9 ,0").
            values = strip.(split(line, ',')[2:end])
            length(values) == length(columns) && push!(breakpoints, Dict(zip(columns, values)))
        elseif occursin(',', line)
            name, value = split(line, ','; limit=2)
            push!(settings, strip(name) => strip(value))
        end
    end
    return MethodDump(settings, columns, breakpoints)
end

# Event text for the start of a run, recorded once the new run's log is open.
const PENDING_METHOD_EVENT = Ref{Union{Nothing,String}}(nothing)

# Take the run's starting state from the first breakpoint.
function apply_method_dump!(app::AppState, m::MethodDump)
    @info "Method settings: " * join(("$k = $v" for (k, v) in m.settings), "; ")
    isempty(m.breakpoints) && (@warn "Method dump without breakpoints"; return)
    bp = m.breakpoints[1]
    inst = app.inst[]

    port = tryparse(Int, get(bp, "Buff", ""))
    if !isnothing(port) && 1 <= port <= 8
        inst.buffer_port = port
        inst.buffer_port_known = true
    end
    inj = lowercase(get(bp, "Inj", ""))
    inst.inject_value = inj == "load" ? IV_LOAD : inj == "inj" ? IV_INJECT :
                        inj == "waste" ? IV_WASTE : inst.inject_value
    notify(app.inst)

    txt = "Method start: flow $(get(bp, "Flow", "?")) ml/min, $(get(bp, "Conc", "?")) %B, " *
          "buffer port $(get(bp, "Buff", "?")), inject $(get(bp, "Inj", "?")), " *
          "fraction $(get(bp, "Frac", "?")) ml, $(length(m.breakpoints)) breakpoints"
    @info txt
    PENDING_METHOD_EVENT[] = txt
end
