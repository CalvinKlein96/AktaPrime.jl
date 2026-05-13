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
# main — application entry point
# ─────────────────────────────────────────────────────────────────────────────
function main()
    # Show @debug messages in the terminal
    global_logger(ConsoleLogger(stderr, Logging.Debug))

    @info "Akta PRIME logger starting"

    # ── CSV filename prompt ────────────────────────────────────────────────────
    default_name = "akta_" * Dates.format(Dates.now(), "yyyymmdd_HHMMSS") * ".csv"
    print("Log filename [$default_name]: ")
    input = strip(readline())
    csv_filename = isempty(input) ? default_name : input

    app = AppState()
    app.csv_io = init_csv(csv_filename)

    # ── Build and open the GUI ─────────────────────────────────────────────────
    fig    = build_gui(app)
    screen = display(fig)
    @info "GUI opened — connecting to Akta at $SERIAL_PORT"

    # ── Start the link layer in an async task ──────────────────────────────────
    tx_queue = Channel{Tuple{UInt16,Vector{UInt8}}}(32)
    shutdown = Ref(false)
    link_task = @async run_linklayer(tx_queue, shutdown, app)

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
        # give the link task a moment to finish gracefully
        try; wait(link_task); catch; end
    end
end

end # module
