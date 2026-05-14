# types.jl — shared data structures for the Akta application

"""One trend data sample with cumulative time/volume coordinates."""
struct TrendPoint
    cum_time_ms::Float64   # cumulative run time from base, ms
    cum_vol_mL::Float64   # cumulative run volume from base, mL
    uv::Float64   # UV absorbance, AU
    cond_mScm::Float64   # conductivity, mS/cm
    ph_raw::Int32     # pH 11-bit ADC value (scale TBD)
    pctb::Float64   # gradient %B (0–100)
    pres::Float64   # pressure (raw ÷ 1000; unit TBD)
    temp_degC::Float64   # temperature, °C
end

@enum EventKind begin
    EVT_CONNECT
    EVT_DISCONNECT
    EVT_RUN_STATE
    EVT_INJECT
    EVT_TUBEFEED
    EVT_LOG
    EVT_STEP
end

@enum InjectValue begin
    IV_LOAD
    IV_INJECT
    IV_WASTE
    IV_UNKNOWN
end

"""A discrete instrument event tagged with run coordinates."""
struct AktaEvent
    cum_time_ms::Float64
    cum_vol_mL::Float64
    kind::EventKind
    text::String
end

"""Live instrument status — mutated in place, then notify(app.inst) called."""
mutable struct InstrumentState
    run_state::String
    cum_time_ms::Float64
    cum_vol_mL::Float64
    run_time_ms::Float64
    run_vol_mL::Float64
    inject_value::InjectValue
    prog_name::String
    version::String
    step_time_ms::Float64
    step_vol_mL::Float64
    fraction_number::Int
    fraction_vol_mL::Float64
end
InstrumentState() = InstrumentState("---", 0.0, 0.0, 0.0, 0.0, IV_UNKNOWN, "", "", 0.0, 0.0, 1, 0.0)

"""
Application-wide shared state.  Passed to OPC handlers and the CSV writer.
The three Observables are the source of truth for the GUI; they are notified
from the link-layer @async task (single OS thread, cooperative scheduling).
"""
mutable struct AppState
    # Observables observed by the GUI
    trend_data::Observable{Vector{TrendPoint}}
    events::Observable{Vector{AktaEvent}}
    inst::Observable{InstrumentState}
    iszoomed::Observable{Bool}

    # multi-frame log message buffer (OPC 0x8005–0x8007)
    log_buf::String

    # open CSV file (nothing until the user confirms a filename)
    csv_io::Union{IO,Nothing}

    # log filename shown in the GUI status panel
    log_filename::String
end

AppState() = AppState(
    Observable(TrendPoint[]),
    Observable(AktaEvent[]),
    Observable(InstrumentState()),
    Observable(false),
    "",
    nothing,
    "",
)

# ── helpers ──────────────────────────────────────────────────────────────────

function push_event!(app::AppState, kind::EventKind, text::String)
    inst = app.inst[]
    ev = AktaEvent(inst.cum_time_ms, inst.cum_vol_mL, kind, text)
    push!(app.events[], ev)
    notify(app.events)
    write_csv_event(app, ev)
    @info "[$kind] $text"
end
