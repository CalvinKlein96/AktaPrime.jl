module Akta

using Dates
using Logging
using Printf
using Observables
using GLMakie
using LibSerialPort

include("types.jl")
include("csv_writer.jl")   # must come before protocol (push_event! calls write_csv_event)
include("protocol.jl")
include("gui.jl")

export main

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
        pctb = clamp(t_min < 3.0 ? 5.0 : 5.0 + 30.0 * (t_min - 3.0), 5.0, 100.0)
        pres = 0.40 + 0.02 * sin(t_min * 2.0)

        # Keep InstrumentState accumulators in sync so push_event! timestamps events correctly.
        s = app.inst[]
        s.cum_time_ms = t_ms
        s.cum_vol_mL = v_mL

        pt = TrendPoint(t_ms, v_mL, uv, cond, Int32(512), pctb, pres, 22.0)
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
function main(filename::Union{String,Nothing}=nothing)
    global_logger(ConsoleLogger(stderr, Logging.Info))

    # ── Replay mode: load an existing CSV log and display it ──────────────────
    if filename !== nothing
        isfile(filename) || (@error "File not found: $filename"; return)
        @info "Replay mode — loading \"$filename\""

        app = AppState()
        load_csv_log!(app, filename)
        app.log_filename = filename

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
        return
    end

    # ── Live / demo mode ──────────────────────────────────────────────────────
    @info "Akta PRIME logger starting"

    # ── Check serial port availability ─────────────────────────────────────────
    demo_mode = false
    try
        sp_check = LibSerialPort.open(SERIAL_PORT, BAUD_RATE)
        LibSerialPort.close(sp_check)
    catch
        @warn "Serial port $SERIAL_PORT not available — will use demo mode"
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
        @info "Connecting to Akta at $SERIAL_PORT…"
        @async Base.invokelatest(run_linklayer, tx_queue, shutdown, app)
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

    # ── CSV filename prompt ────────────────────────────────────────────────────
    tag = demo_mode ? "demo_" : ""
    default_name = "akta_$(tag)$(Dates.format(Dates.now(), "yyyymmdd_HHMMSS")).csv"
    print("Log filename [$default_name]: ")
    input = strip(readline())
    csv_filename = isempty(input) ? default_name : input
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

end # module
