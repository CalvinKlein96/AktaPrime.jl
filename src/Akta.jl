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
    # At 1 mL/min: inject at t=2.5 min (step 75), gradient at t=3 min (step 90),
    # UV peak at t=4 min (step 120).
    step = 0
    while !shutdown[]
        sleep(0.2)
        step += 1
        t_ms  = step * 2_000.0          # 2 s per step
        v_mL  = t_ms * (1.0 / 60_000)  # 1 mL/min
        t_min = t_ms / 60_000

        uv   = 0.02 + 1.2 * exp(-((t_min - 4.0)^2) / (2 * 0.4^2)) +
                      0.5 * exp(-((t_min - 6.5)^2) / (2 * 0.2^2))
        cond = 10.0 + 2.0 * sin(t_min * 0.5)
        pctb = clamp(t_min < 3.0 ? 5.0 : 5.0 + 30.0 * (t_min - 3.0), 5.0, 100.0)
        pres = 0.40 + 0.02 * sin(t_min * 2.0)

        # Keep accumulators in sync so push_event! timestamps events correctly.
        app.cum_time_ms = t_ms
        app.cum_vol_mL  = v_mL

        pt = TrendPoint(t_ms, v_mL, uv, cond, Int32(512), pctb, pres, 22.0)
        push!(app.trend_data[], pt)
        notify(app.trend_data)
        write_csv_trend(app, pt)

        s = app.inst[]
        s.run_time_ms = t_ms
        s.run_vol_mL  = v_mL
        notify(app.inst)

        if step == 75       # t = 2.5 min — inject
            app.inst[].inject_active = true; notify(app.inst)
            push_event!(app, EVT_INJECT, "Valve → INJECT (demo)")
        elseif step == 90   # t = 3.0 min — gradient start / return to load
            app.inst[].inject_active = false; notify(app.inst)
            push_event!(app, EVT_INJECT, "Valve → LOAD (demo)")
            push_event!(app, EVT_STEP,   "Gradient start (demo)")
        elseif step == 300  # t = 10 min — end of run
            app.inst[].run_state = "End"; notify(app.inst)
            push_event!(app, EVT_RUN_STATE, "Run complete (demo)")
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# main — application entry point
# ─────────────────────────────────────────────────────────────────────────────
function main()
    global_logger(ConsoleLogger(stderr, Logging.Info))
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
