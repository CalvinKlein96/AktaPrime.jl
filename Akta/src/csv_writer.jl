# csv_writer.jl — CSV logging, flushed after every row

const CSV_HEADER = "wall_time,cum_time_ms,cum_vol_mL,type," *
                   "uv_AU,cond_mScm,ph_raw,pctb_pct,pres,temp_degC,message\n"

"""Open (or create) a CSV log file and write the header."""
function init_csv(filename::String)::IO
    io = open(filename, "w")
    write(io, "# Akta PRIME data log started $(Dates.now())\n")
    write(io, CSV_HEADER)
    flush(io)
    @info "Logging to $filename"
    return io
end

function write_csv_trend(app::AppState, pt::TrendPoint)
    isnothing(app.csv_io) && return
    io = app.csv_io
    t = Dates.now()
    @printf(io, "%s,%.1f,%.6f,TREND,%.8f,%.4f,%d,%.2f,%.4f,%.2f,\n",
            t, pt.cum_time_ms, pt.cum_vol_mL,
            pt.uv, pt.cond_mScm, pt.ph_raw, pt.pctb, pt.pres, pt.temp_degC)
    flush(io)
end

function write_csv_event(app::AppState, ev::AktaEvent)
    isnothing(app.csv_io) && return
    io = app.csv_io
    t = Dates.now()
    msg = replace(ev.text, ',' => ';', '\n' => ' ')
    @printf(io, "%s,%.1f,%.6f,%s,,,,,,,\"%s\"\n",
            t, ev.cum_time_ms, ev.cum_vol_mL, string(ev.kind), msg)
    flush(io)
end
