# gui.jl — GLMakie real-time chromatography display

# ── Colour palette ────────────────────────────────────────────────────────────
const COL_UV   = RGBf(0.15, 0.35, 0.70)
const COL_COND = RGBf(0.80, 0.20, 0.10)
const COL_PCTB = RGBf(0.10, 0.55, 0.25)
const COL_PRES = RGBf(0.75, 0.45, 0.00)

const EVT_COLORS = Dict(
    EVT_INJECT     => (:purple,   :dash),
    EVT_RUN_STATE  => (:gray50,   :dash),
    EVT_STEP       => (:teal,     :dashdot),
    EVT_TUBEFEED   => (:brown,    :dot),
    EVT_LOG        => (:gray70,   :dot),
    EVT_CONNECT    => (:green,    :solid),
    EVT_DISCONNECT => (:red,      :solid),
)

# ─────────────────────────────────────────────────────────────────────────────
# build_gui — construct the Figure and wire all Observables
# ─────────────────────────────────────────────────────────────────────────────
function build_gui(app::AppState)::Figure
    fig = Figure(size=(1440, 900), backgroundcolor=:white)

    # ── Chromatogram axes (left column, rows 1–4) ─────────────────────────────
    ax_uv   = Axis(fig[1, 1]; ylabel="UV (AU)",      xticklabelsvisible=false,
                   ygridvisible=true, xgridvisible=false)
    ax_cond = Axis(fig[2, 1]; ylabel="Cond (mS/cm)", xticklabelsvisible=false,
                   ygridvisible=true, xgridvisible=false)
    ax_pctb = Axis(fig[3, 1]; ylabel="%B",            xticklabelsvisible=false,
                   ygridvisible=true, xgridvisible=false,
                   limits=(nothing, (0, 105)))
    ax_pres = Axis(fig[4, 1]; ylabel="Pressure",      xlabel="Time (min)",
                   ygridvisible=true, xgridvisible=false)

    linkxaxes!(ax_uv, ax_cond, ax_pctb, ax_pres)

    # Reduce vertical gap between stacked panels
    rowgap!(fig.layout, 1, 4)
    rowgap!(fig.layout, 2, 4)
    rowgap!(fig.layout, 3, 4)

    # ── Compute graph: derive individual series from single Observable ─────────
    t_min    = @lift [p.cum_time_ms / 60_000     for p in $(app.trend_data)]
    uv_arr   = @lift [p.uv                        for p in $(app.trend_data)]
    cond_arr = @lift [p.cond_mScm                 for p in $(app.trend_data)]
    pctb_arr = @lift [p.pctb                      for p in $(app.trend_data)]
    pres_arr = @lift [p.pres                      for p in $(app.trend_data)]

    lines!(ax_uv,   t_min, uv_arr,   color=COL_UV,   linewidth=1.5)
    lines!(ax_cond, t_min, cond_arr, color=COL_COND,  linewidth=1.5)
    lines!(ax_pctb, t_min, pctb_arr, color=COL_PCTB,  linewidth=1.5)
    lines!(ax_pres, t_min, pres_arr, color=COL_PRES,  linewidth=1.5)

    # ── Event markers on the UV panel ─────────────────────────────────────────
    # `let` captures loop variables by value to avoid closure-over-mutable issues
    for kind in instances(EventKind)
        let kind = kind
            color, style = get(EVT_COLORS, kind, (:black, :dash))
            evts_k  = @lift filter(e -> e.kind == kind, $(app.events))
            evt_t_k = @lift [e.cum_time_ms / 60_000 for e in $evts_k]
            vlines!(ax_uv, evt_t_k; color=(color, 0.55), linestyle=style, linewidth=1.0)
        end
    end

    # ── Event legend ──────────────────────────────────────────────────────────
    legend_elements = [LineElement(color=EVT_COLORS[k][1], linestyle=EVT_COLORS[k][2])
                       for k in (EVT_INJECT, EVT_RUN_STATE, EVT_STEP, EVT_LOG)]
    legend_labels   = ["Inject", "State", "Step", "Log"]
    Legend(fig[5, 1], legend_elements, legend_labels;
           orientation=:horizontal, framevisible=false, tellwidth=false,
           labelsize=11, patchsize=(18, 2))

    # ── Status panel (right column, rows 1–3) ─────────────────────────────────
    status_text = Observable("Connecting…")
    Label(fig[1, 2], "INSTRUMENT STATUS"; halign=:left, fontsize=12, font=:bold,
          tellwidth=false, padding=(8, 0, 4, 0))
    Label(fig[2, 2], status_text;
          halign=:left, valign=:top, tellwidth=false, tellheight=false,
          font=:mono, fontsize=11, padding=(8, 8, 0, 0))

    on(app.inst) do s
        inj = s.inject_active ? "● ACTIVE" : "○ inactive"
        t_s = @sprintf("%.1f", s.run_time_ms / 1000)
        v   = @sprintf("%.4f", s.run_vol_mL)
        st  = @sprintf("%.1f", s.step_time_ms / 1000)
        sv  = @sprintf("%.4f", s.step_vol_mL)
        status_text[] = """
State:   $(rpad(s.run_state, 10))  Inject: $inj
Run t:   $t_s s
Run v:   $v mL
Step t:  $st s
Step v:  $sv mL
Prog:    $(isempty(s.prog_name) ? "---" : s.prog_name)
Ver:     $(isempty(s.version) ? "---" : s.version)"""
    end

    # ── Flow path schematic (right column, rows 3–5) ──────────────────────────
    ax_flow = Axis(fig[3:5, 2];
                   title="Flow Path", titlesize=12,
                   aspect=nothing,
                   xticksvisible=false, yticksvisible=false,
                   xticklabelsvisible=false, yticklabelsvisible=false,
                   leftspinevisible=false, rightspinevisible=false,
                   topspinevisible=false, bottomspinevisible=false,
                   limits=(0, 10, 0, 8))

    _draw_flow_schematic!(ax_flow, app)

    # ── Column proportions ────────────────────────────────────────────────────
    colsize!(fig.layout, 1, Relative(0.73))
    colsize!(fig.layout, 2, Relative(0.27))
    rowsize!(fig.layout, 2, Relative(0.30))   # status text gets more height

    return fig
end

# ─────────────────────────────────────────────────────────────────────────────
# _draw_flow_schematic! — static schematic + reactive colouring
#
# Layout (x 0–10, y 0–8):
#
#   BufA (1,6.5) ─┐
#                  ├─ Pump (2.5,5) ─ InjectV (4.5,5) ─ Column (6,5) ─ Det (7.5,5) ─ Out (9,5)
#   BufB (1,3.5) ─┘                      │
#                                       Loop (4.5,3.5)
# ─────────────────────────────────────────────────────────────────────────────
function _draw_flow_schematic!(ax, app::AppState)
    # Helper: draw a labelled rounded rectangle
    function box!(ax, cx, cy, w, h, label; color=:lightblue, fontsize=9)
        rect = Rect2f(cx - w/2, cy - h/2, w, h)
        poly!(ax, rect; color=color, strokecolor=:black, strokewidth=1)
        text!(ax, cx, cy; text=label, fontsize=fontsize,
              align=(:center, :center), font=:bold)
    end

    # Main flow spine
    lines!(ax, [1.8, 2.5, 3.5, 4.5, 5.5, 6.0, 7.0, 7.5, 8.3, 9.0],
               [5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0];
           color=:steelblue, linewidth=2.5)
    # A inlet
    lines!(ax, [1.0, 1.0, 1.8], [6.5, 5.0, 5.0]; color=:steelblue, linewidth=2.5)
    # B inlet
    lines!(ax, [1.0, 1.0, 1.8], [3.5, 5.0, 5.0]; color=:steelblue, linewidth=2.5)
    # Sample loop off inject valve
    lines!(ax, [4.5, 4.5, 5.5, 5.5], [4.7, 3.5, 3.5, 4.7];
           color=:gray60, linewidth=1.5, linestyle=:dash)

    # Static component boxes
    box!(ax, 1.0, 6.5, 0.7, 0.55, "BufA"; color=(:lightblue, 0.7))
    box!(ax, 1.0, 3.5, 0.7, 0.55, "BufB"; color=(:lightblue, 0.7))
    box!(ax, 2.5, 5.0, 0.9, 0.60, "PUMP"; color=(:skyblue, 0.9))
    box!(ax, 6.0, 5.0, 0.9, 0.60, "COL";  color=(:wheat, 0.9))
    box!(ax, 7.5, 5.0, 1.3, 0.60, "UV\nCOND"; color=(:lightyellow, 0.9), fontsize=8)
    box!(ax, 9.0, 5.0, 0.8, 0.55, "OUT";  color=(:lightgreen, 0.7))
    text!(ax, 5.0, 3.5; text="loop", fontsize=8, color=:gray50, align=(:center, :center))

    # %B annotation near pump (reactive)
    pctb_text = @lift begin
        td = $(app.trend_data)
        isempty(td) ? "" : @sprintf("%%B = %.1f%%", td[end].pctb)
    end
    text!(ax, 2.5, 4.2; text=pctb_text, fontsize=9,
          align=(:center, :center), color=COL_PCTB)

    # Injection valve — reactive colour (purple = injecting, gray = load)
    inj_color = @lift $(app.inst).inject_active ? (:orchid, 0.95) : (:lightgray, 0.95)
    inj_label = @lift $(app.inst).inject_active ? "INJ\n●" : "INJ\n○"
    poly!(ax, Rect2f(4.5 - 0.5, 5.0 - 0.35, 1.0, 0.70);
          color=inj_color, strokecolor=:black, strokewidth=1)
    text!(ax, 4.5, 5.0; text=inj_label, fontsize=8,
          align=(:center, :center), font=:bold)

    # Run state banner at top
    state_text  = @lift $(app.inst).run_state
    state_color = @lift begin
        s = $(app.inst).run_state
        s == "Run"      ? (:green,  1.0) :
        s == "Pause"    ? (:orange, 1.0) :
        s == "Hold"     ? (:orange, 1.0) :
        s == "Continue" ? (:blue,   1.0) :
        s == "End"      ? (:red,    1.0) :
                          (:gray,   1.0)
    end
    text!(ax, 5.0, 7.4; text=state_text, fontsize=14, font=:bold,
          align=(:center, :center), color=state_color)
end
