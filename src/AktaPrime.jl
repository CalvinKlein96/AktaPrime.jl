module AktaPrime

using Dates
using Logging
using Printf
using Observables
using GLMakie
using LibSerialPort
using Preferences

include("types.jl")
include("csv_writer.jl")   # must come before protocol (push_event! calls write_csv_event)
include("protocol.jl")
include("gui.jl")

export main

const SERIAL_PORT_PREFERENCE_KEY = "serial_port"

_is_logfile_arg(path::AbstractString)::Bool = endswith(lowercase(path), ".csv")

function _effective_serial_port(serial_override::Union{Nothing,AbstractString})::String
    if serial_override === nothing
        return @load_preference(SERIAL_PORT_PREFERENCE_KEY, DEFAULT_SERIAL_PORT)
    end
    serial_port = String(serial_override)
    @set_preferences!(SERIAL_PORT_PREFERENCE_KEY => serial_port)
    return serial_port
end

function _run_replay(filename::AbstractString)
    filename_str = String(filename)
    isfile(filename_str) || (@error "File not found: $filename_str"; return)
    @info "Replay mode - loading \"$filename_str\""

    app = AppState()
    load_csv_log!(app, filename_str)
    app.log_filename = filename_str

    fig = build_gui(app)
    screen = display(fig)
    @info "GUI opened (replay)"

    Base.exit_on_sigint(false)
    try
        while isopen(screen)
            sleep(0.05)
        end
    catch e
        e isa InterruptException || rethrow()
        @info "Interrupted"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# run_demo — simulated Akta data stream for testing without hardware
# ─────────────────────────────────────────────────────────────────────────────
function run_demo(shutdown::Ref{Bool}, app::AppState)
    push_event!(app, EVT_CONNECT, "Demo mode — simulated Akta")
    app.inst[].run_state = "Run"
    notify(app.inst)

    # 2 s of simulated time per step, 0.2 s sleep → 10× real-time speedup.
    # Flow rate varies between 0.5–2.0 mL/min so time and volume axes diverge visibly.
    step = 0
    cum_vol = 0.0      # accumulated volume in mL (not derived from fixed flow)
    while !shutdown[]
        sleep(0.2)
        step += 1
        t_ms = step * 2_000.0          # 2 s per step (fixed time)
        t_min = t_ms / 60_000

        # Flow rate: 1 mL/min baseline with a slow sinusoidal variation ±0.5 mL/min
        flow_mL_per_min = 1.0 + 0.5 * sin(t_min * 0.8)
        flow_mL_per_ms = flow_mL_per_min / 60_000
        cum_vol += flow_mL_per_ms * 2_000.0  # Δv for this 2 s step
        v_mL = cum_vol

        uv = 0.02 + 1.2 * exp(-((t_min - 4.0)^2) / (2 * 0.4^2)) +
             0.5 * exp(-((t_min - 6.5)^2) / (2 * 0.2^2))
        cond = 10.0 + 2.0 * sin(t_min * 0.5)
        ph = 7.0 + 0.4 * sin(t_min * 0.3)
        pctb = clamp(t_min < 3.0 ? 5.0 : 5.0 + 30.0 * (t_min - 3.0), 5.0, 100.0)
        pres = 0.40 + 0.02 * sin(t_min * 2.0)

        # Keep InstrumentState accumulators in sync so push_event! timestamps events correctly.
        s = app.inst[]
        s.cum_time_ms = t_ms
        s.cum_vol_mL = v_mL

        pt = TrendPoint(t_ms, v_mL, uv, cond, ph, pctb, pres, 22.0)
        push!(app.trend_data[], pt)
        notify(app.trend_data)
        write_csv_trend(app, pt)

        s.run_time_ms = t_ms
        s.run_vol_mL = v_mL
        notify(app.inst)

        # Cycle inject state every 40 demo steps: UNKNOWN -> LOAD -> INJECT -> WASTE.
        if (step - 1) % 40 == 0
            valves = (IV_UNKNOWN, IV_LOAD, IV_INJECT, IV_WASTE)
            idx = mod((step - 1) ÷ 40, length(valves)) + 1
            new_valve = valves[idx]
            app.inst[].inject_value = new_valve
            notify(app.inst)
            push_event!(app, EVT_INJECT, "Valve → $(_inject_label(new_valve)) (demo)")
        end

        # Cycle fraction size every 30 steps, including zero (= route to waste).
        if (step - 1) % 30 == 0
            sizes = (0.0, 0.5, 1.0, 2.0)
            idx = mod((step - 1) ÷ 30, length(sizes)) + 1
            new_size = sizes[idx]
            app.inst[].fraction_vol_mL = new_size
            if update_fraction_state!(app)
                notify(app.fractions)
            end
            notify(app.inst)
            push_event!(app, EVT_LOG, @sprintf("Fraction size %.1f ml", new_size))
        end

        # Advance fraction number periodically only when fraction collection is active.
        if step % 20 == 0 && app.inst[].fraction_vol_mL > 0
            app.inst[].fraction_number += 1
            if update_fraction_state!(app)
                notify(app.fractions)
            end
            notify(app.inst)
            push_event!(app, EVT_TUBEFEED, "Feed Tube Nr $(app.inst[].fraction_number)")
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# main — application entry point
# ─────────────────────────────────────────────────────────────────────────────
function _run_live(serial_override::Union{Nothing,AbstractString}=nothing)
    global_logger(ConsoleLogger(stderr, Logging.Info))

    # ── Live / demo mode ──────────────────────────────────────────────────────
    @info "Akta PRIME logger starting"
    serial_port = _effective_serial_port(serial_override)

    # ── Check serial port availability ─────────────────────────────────────────
    demo_mode = false
    try
        sp_check = LibSerialPort.open(serial_port, BAUD_RATE)
        LibSerialPort.close(sp_check)
    catch
        @warn "Serial port $serial_port not available - will use demo mode"
        demo_mode = true
    end

    app = AppState()
    tx_queue = Channel{Tuple{UInt16,Vector{UInt8}}}(32)
    shutdown = Ref(false)

    # ── Start link layer or demo runner ────────────────────────────────────────
    link_task = if demo_mode
        @info "Starting demo mode"
        t = @async Base.invokelatest(run_demo, shutdown, app)
        yield()   # let the task push EVT_CONNECT before we begin polling
        t
    else
        @info "Connecting to Akta at $serial_port..."
        @async Base.invokelatest(run_linklayer, tx_queue, shutdown, app, serial_port)
    end

    # ── Wait for EVT_CONNECT ───────────────────────────────────────────────────
    timeout_s = demo_mode ? 3.0 : 30.0
    t0 = time()
    while time() - t0 < timeout_s
        any(e -> e.kind == EVT_CONNECT, app.events[]) && break
        if istaskdone(link_task)
            @error "Link task exited unexpectedly: $(link_task.exception)"
            break
        end
        sleep(0.1)
    end

    if !any(e -> e.kind == EVT_CONNECT, app.events[])
        @error "No Akta connection after $(Int(timeout_s)) s — aborting"
        shutdown[] = true
        return
    end

    # ── CSV log-prefix prompt ──────────────────────────────────────────────────
    # A new run automatically rolls over to a fresh "<prefix>_<timestamp>.csv",
    # so we collect a base name here rather than a single fixed filename.
    default_prefix = demo_mode ? "akta_demo" : "akta"
    sleep(0.5)
    print("Log file prefix [$default_prefix]: ")
    input = strip(readline())
    app.log_prefix = isempty(input) ? default_prefix : String(input)
    csv_filename = newlogname(app)
    app.csv_io = init_csv(csv_filename)
    app.log_filename = csv_filename

    # ── Build and open the GUI ─────────────────────────────────────────────────
    fig = build_gui(app)
    screen = display(fig)
    @info "GUI opened"

    # ── Run until the window is closed or Ctrl-C ──────────────────────────────
    Base.exit_on_sigint(false)
    try
        while isopen(screen)
            sleep(0.05)
        end
    catch e
        e isa InterruptException || rethrow()
        @info "Interrupted"
    finally
        shutdown[] = true
        close(app.csv_io)
        @info "CSV closed — $(length(app.trend_data[])) trend points logged"
        try
            wait(link_task)
        catch
        end
    end
end

function main()
    _run_live(nothing)
end

function main(arg::AbstractString)
    if _is_logfile_arg(arg)
        global_logger(ConsoleLogger(stderr, Logging.Info))
        _run_replay(arg)
        return
    end
    _run_live(arg)
end

function main(args::Vector{String})
    if isempty(args)
        return main()
    elseif length(args) == 1
        return main(args[1])
    end
    @error "Usage: AktaPrime [serial_port|logfile.csv]"
    return
end

function (@main)(args)
    main(collect(args))
end

end # module
