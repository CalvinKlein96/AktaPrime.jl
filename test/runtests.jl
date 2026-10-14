# Tests for AktaPrime. Run with:  julia --project=. -e 'using Pkg; Pkg.test()'
# (in CI under xvfb-run, as GLMakie needs a display to load).
#
# `import`, not `using`: `using AktaPrime` would bring the @main entry point into
# Main, and Julia would start the program when this script ends.
import AktaPrime
using Test
const A = AktaPrime

# A method dump as an ÄKTAprime (V2.01) sends it before a run: manual method,
# 0.5 ml/min, 0 %B, buffer valve port 8, injection valve Load.
const METHOD_DUMP = "{l{5}{2 Method Dump}{2}{2 AKTAprime|3Ver|2, V2.01|?}{2}{2 Dump Format Ver|2, V1.00|?}" *
    "{2}{l{5}}}{B}{2 Method Settings}{B}Method Type|8,Manaul Method}Method|=,1}Method base|8,ml}" *
    "Frac base|:,ml}Max pressure (kPa) ,1000}Alarm (min/ml)|5,0.0}}{E}{2 Method Breakpoints}{E}|E}" *
    "Brkp Volume|3Conc Flow|2Frac|3Buff Inj|4Peak|3Autozzero Eventmark}|Z(mAu/min)}}" *
    ",1|3,0.0|5,0|3,0.5|2,0.0|3,8|3,Load|2,0|5,N|7,N},2|3,99999.9 ,0|3,0.5|2,0.0|3,8|3,Load|2,0|5,N|7,N}"

pt(t; vol=t / 2, uv=0.1, pctb=0.0) = A.TrendPoint(t * 60_000, vol, uv, 10.0, 7.0, pctb, 0.3, 20.0)
event(t, kind, text) = A.AktaEvent(t * 60_000, t / 2, kind, text)

@testset "AktaPrime" begin

    @testset "link layer frames" begin
        for (opc, data) in ((A.OPC_IDENTITY_REQUEST, UInt8[0x01]),               # binary, odd length
                            (A.OPC_TREND_DATA, UInt8.(0:13)),                     # binary, even length
                            (A.OPC_LOG_SINGLE, Vector{UInt8}("Flow 0.5 ml/min")))  # ASCII
            @test A.decode_opc_payload(A.encode_opc_payload(opc, data)) == [(opc, data)]
        end
        # a frame from the Akta passes validation; a corrupted one does not
        frame = UInt8[A.FRAME_START, A.AKTA_ADDR, A.CTRL_CONN, 0x00, A.FRAME_END]
        frame[4] = A.compute_checksum(frame, 2, 2)
        @test A.validate_rx_frame(frame, length(frame))
        frame[3] ⊻= 0x01
        @test !A.validate_rx_frame(frame, length(frame))
    end

    @testset "volume unit" begin
        A.VOLUME_UNIT_UL[] = 1.0          # ÄKTAprime: 1 µL per count
        @test A._vol_mL(1000) ≈ 1.0
        A.VOLUME_UNIT_UL[] = 10.0         # ÄKTAprime plus: 10 µL per count
        @test A._vol_mL(1000) ≈ 10.0
    end

    @testset "run time and volume advance with trend data" begin
        A.VOLUME_UNIT_UL[] = 1.0
        app = A.AppState(); app.csv_io = devnull
        data = zeros(UInt8, 14); data[1] = 10; data[2] = 1      # Δt = 100 ms, Δv = 1 µL
        A._handle_trend_data(copy(data), app)                    # not running: no change
        @test app.inst[].run_time_ms == 0
        app.inst[].run_state = "Run"
        foreach(_ -> A._handle_trend_data(copy(data), app), 1:600)
        @test app.inst[].run_time_ms ≈ 60_000
        @test app.inst[].run_vol_mL ≈ 0.6
    end

    @testset "method dump" begin
        m = A.parse_method_dump(Vector{UInt8}(METHOD_DUMP))
        @test Dict(m.settings)["Max pressure (kPa)"] == "1000"
        @test m.columns == ["Brkp", "Volume", "Conc", "Flow", "Frac", "Buff", "Inj", "Peak", "Autozero", "Eventmark"]
        @test length(m.breakpoints) == 2                          # incl. the end row "99999.9 ,0"
        @test m.breakpoints[1]["Buff"] == "8"
        @test m.breakpoints[1]["Flow"] == "0.5"
        @test m.breakpoints[2]["Volume"] == "99999.9"
        app = A.AppState()
        A.apply_method_dump!(app, m)
        @test app.inst[].buffer_port == 8 && app.inst[].buffer_port_known
        @test app.inst[].inject_value == A.IV_LOAD
        @test occursin("buffer port 8", A.PENDING_METHOD_EVENT[])
        A.PENDING_METHOD_EVENT[] = nothing
    end

    @testset "valve log messages" begin
        s = A.InstrumentState()
        @test !s.buffer_port_known && s.buffer_port == 1          # assumed until reported
        @test A._set_buffer_valve_from_log!("Buffer Valve Pos 8", s) && s.buffer_port == 8
        @test A._set_buffer_valve_from_log!("Manual Set; Buffer Valve Pos 3", s) && s.buffer_port == 3
        @test !A._set_buffer_valve_from_log!("Buffer Valve Pos 9", s) && s.buffer_port == 3
        @test A._set_inject_from_log!("Injection Valve Inj", s) && s.inject_value == A.IV_INJECT
        @test A._flow_from_log("Flow 0.5 ml/min") == 0.5
        @test isnothing(A._flow_from_log("Concentration 10 %B"))
    end

    @testset "state at a past moment" begin
        events = [event(0.1, A.EVT_LOG, "Method start: flow 0.5 ml/min, 0 %B, buffer port 1, inject Load, fraction 0.0 ml, 2 breakpoints"),
            event(0.2, A.EVT_RUN_STATE, "Run state: Run  inject=IV_LOAD"),
            event(1.0, A.EVT_LOG, "Buffer Valve Pos 8"),
            event(3.0, A.EVT_LOG, "Fraction size 1.0 ml"),
            event(4.0, A.EVT_LOG, "Injection Valve Inj")]
        s = A._state_at(events, pt(2.0))
        @test s.run_state == "Run" && s.buffer_port == 8 && s.inject_value == A.IV_LOAD && s.fraction_vol_mL == 0
        s = A._state_at(events, pt(5.0))
        @test s.inject_value == A.IV_INJECT && s.fraction_vol_mL == 1.0
        @test A._state_at(events, pt(0.05)).inject_value == A.IV_UNKNOWN
        @test A._flow_at([event(0.5, A.EVT_LOG, "Flow 0.5 ml/min")], pt(1.0)) == 0.5
    end

    @testset "run information" begin
        app = A.AppState()
        A.log_run_info!(app, Dict("Sample" => "Lysozyme", "Column volume (mL)" => "2,5", "Port 3" => "Tris"))
        info = A.run_info(app.events[])
        @test info["Sample"] == "Lysozyme" && info["Port 3"] == "Tris"
        @test A.column_volume(info) == 2.5                      # decimal comma accepted
        n = length(app.events[])
        A.log_run_info!(app, Dict("Sample" => "Lysozyme", "User" => "C"); only_changed=true)
        @test length(app.events[]) == n + 1                     # only the new field is recorded
    end

    @testset "CSV log round trip" begin
        dir = mktempdir()
        app = A.AppState(); app.log_dir = dir; app.log_prefix = "test"
        app.log_filename = A.newlogname(app)
        @test dirname(app.log_filename) == dir
        app.csv_io = A.init_csv(app.log_filename)
        points = [pt(t; uv=sin(t)) for t in 0:0.1:2]
        foreach(p -> A.write_csv_trend(app, p), points)
        A.push_event!(app, A.EVT_MARK, "sample loaded")
        A.push_event!(app, A.EVT_INFO, "Sample: Lysozyme")
        close(app.csv_io)
        back = A.AppState(); A.load_csv_log!(back, app.log_filename)
        @test length(back.trend_data[]) == length(points)
        @test back.trend_data[][end].uv ≈ points[end].uv atol = 1e-6
        @test [e.kind for e in back.events[]] == [A.EVT_MARK, A.EVT_INFO]
    end

    @testset "display downsampling" begin
        trend = [pt(i / 480; uv=i == 5000 ? 9.0 : 0.0) for i in 1:30_000]
        all_pts = A._display_points(trend, p -> p.uv, 0.0, (-Inf, Inf))
        @test length(all_pts) <= 2 * A.DISPLAY_BINS
        @test maximum(p[2] for p in all_pts) == 9.0              # a one-point peak survives
        zoom = A._display_points(trend, p -> p.uv, 0.0, (10.0, 11.0))
        @test length(zoom) == 482                                # all 480 points in the window + 2 edges
        @test A._normalise([A.Point2f(0, 2), A.Point2f(1, 4)], :uv)[1][2][2] ≈ 100
    end

    @testset "settings defaults" begin
        s = A.Settings(false, "/dev/ttyUSB0", 1.0, "akta", "", false, 2.0, Dict{String,String}())
        @test s.start_panels == A.ALL_PANELS && !s.save_raw
    end

    @testset "GUI pages build" begin
        app = A.AppState(); app.csv_io = devnull
        foreach(t -> push!(app.trend_data[], pt(t; pctb=10t)), 0:0.01:3)
        push!(app.events[], event(1.0, A.EVT_LOG, "Buffer Valve Pos 3"))
        settings = A.Settings(true, "/dev/null", 1.0, "test", mktempdir(), false, 2.0, Dict{String,String}())
        acq = A.Acquisition(app, settings)
        ws = A.Workspace(acq)
        live = A.add_page!((tb, os) -> A.build_gui(app; topbar=tb, on_screen=os, status=acq.status), ws, "Live";
            closable=false)
        A.show_page!(ws, live)
        @test live.fig isa A.Figure
        @test A.build_gui(app; viewer=true, start_panels=["%B"]) isa A.Figure
        A.show_page!(ws, A.prepare_settings!(ws))
        A.open_runinfo!(ws)
        @test [p.title for p in ws.pages] == ["Live", "Settings", "Run info"]
    end
end
