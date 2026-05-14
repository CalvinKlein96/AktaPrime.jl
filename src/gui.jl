# gui.jl — GLMakie real-time chromatography display

# ── Colour palette ────────────────────────────────────────────────────────────
const COL_UV   = RGBf(0.15, 0.35, 0.70)
const COL_COND = RGBf(0.80, 0.20, 0.10)
const COL_PCTB = RGBf(0.10, 0.55, 0.25)
const COL_PRES = RGBf(0.75, 0.45, 0.00)

const COL_BUF_A = RGBf(0.80, 0.10, 0.10)   # red
const COL_BUF_B = RGBf(0.90, 0.80, 0.05)   # yellow

const EVT_COLORS = Dict(
    EVT_INJECT    => (:purple, :dash),
    EVT_RUN_STATE => (:gray50, :dash),
    EVT_STEP      => (:teal,   :dashdot),
    EVT_TUBEFEED  => (:brown,  :dot),
    EVT_LOG       => (:gray70, :dot),
    EVT_CONNECT   => (:green,  :solid),
    EVT_DISCONNECT=> (:red,    :solid),
)

# ─────────────────────────────────────────────────────────────────────────────
# build_gui — construct the Figure and wire all Observables
# ─────────────────────────────────────────────────────────────────────────────
function build_gui(app::AppState)::Figure
    fig = Figure(size=(1440, 900), backgroundcolor=:white)

    # Two independent sub-layouts: plots left, status+flow right.
    # Nesting gives each side its own row-size control.
    left  = fig[1, 1] = GridLayout()
    right = fig[1, 2] = GridLayout()
    colsize!(fig.layout, 1, Relative(0.72))
    colsize!(fig.layout, 2, Relative(0.28))

    # ── Chromatogram axes ─────────────────────────────────────────────────────
    ax_uv   = Axis(left[1, 1]; ylabel="UV (AU)",      xticklabelsvisible=false,
                   ygridvisible=true, xgridvisible=false)
    ax_cond = Axis(left[2, 1]; ylabel="Cond (mS/cm)", xticklabelsvisible=false,
                   ygridvisible=true, xgridvisible=false)
    ax_pctb = Axis(left[3, 1]; ylabel="%B",           xticklabelsvisible=false,
                   ygridvisible=true, xgridvisible=false,
                   limits=(nothing, (0, 105)))
    ax_pres = Axis(left[4, 1]; ylabel="Pressure", xlabel="Time (min)",
                   ygridvisible=true, xgridvisible=false)

    linkxaxes!(ax_uv, ax_cond, ax_pctb, ax_pres)

    for row in 1:4
        rowsize!(left, row, Relative(0.22))
    end
    rowgap!(left, 4)

    # ── Data observables ──────────────────────────────────────────────────────
    # Guard: provide a dummy point when empty so GLMakie axis autoscaling
    # never reduces over an empty collection on first render.
    _trend   = @lift let d = $(app.trend_data)
        isempty(d) ? [TrendPoint(0.0, 0.0, 0.0, 0.0, Int32(0), 0.0, 0.0, 0.0)] : d
    end
    t_min    = @lift [p.cum_time_ms / 60_000 for p in $_trend]
    uv_arr   = @lift [p.uv          for p in $_trend]
    cond_arr = @lift [p.cond_mScm   for p in $_trend]
    pctb_arr = @lift [p.pctb        for p in $_trend]
    pres_arr = @lift [p.pres        for p in $_trend]

    lines!(ax_uv,   t_min, uv_arr,   color=COL_UV,   linewidth=1.5)
    lines!(ax_cond, t_min, cond_arr, color=COL_COND,  linewidth=1.5)
    lines!(ax_pctb, t_min, pctb_arr, color=COL_PCTB,  linewidth=1.5)
    lines!(ax_pres, t_min, pres_arr, color=COL_PRES,  linewidth=1.5)

    # ── Event vlines on UV panel ──────────────────────────────────────────────
    # xautolimits/yautolimits=false prevents Makie calling extrema on empty vectors.
    for kind in instances(EventKind)
        let kind = kind
            color, style = get(EVT_COLORS, kind, (:black, :dash))
            evts_k  = @lift filter(e -> e.kind == kind, $(app.events))
            evt_t_k = @lift [e.cum_time_ms / 60_000 for e in $evts_k]
            vlines!(ax_uv, evt_t_k; color=(color, 0.55), linestyle=style, linewidth=1.0,
                    xautolimits=false, yautolimits=false)
        end
    end

    # ── Event legend ──────────────────────────────────────────────────────────
    legend_elements = [LineElement(color=EVT_COLORS[k][1], linestyle=EVT_COLORS[k][2])
                       for k in (EVT_INJECT, EVT_RUN_STATE, EVT_STEP, EVT_LOG)]
    legend_labels   = ["Inject", "State", "Step", "Log"]
    Legend(left[5, 1], legend_elements, legend_labels;
           orientation=:horizontal, framevisible=false, tellwidth=false,
           labelsize=11, patchsize=(18, 2))

    # ── Status panel ──────────────────────────────────────────────────────────
    Label(right[1, 1], "INSTRUMENT STATUS";
          halign=:left, fontsize=12, font=:bold,
          tellwidth=false, padding=(8, 0, 4, 0))

    status_text = Observable("")
    Label(right[2, 1], status_text;
          halign=:left, valign=:top, tellwidth=false, tellheight=false,
          fontsize=11, padding=(8, 8, 0, 0))

    on(app.inst) do s
        inj = s.inject_active ? "● INJECT" : "○ load"
        t_s = @sprintf("%.1f", s.run_time_ms / 1000)
        v   = @sprintf("%.4f", s.run_vol_mL)
        status_text[] = """
State:  $(rpad(s.run_state, 10))  Valve: $inj
Run t:  $t_s s
Run v:  $v mL
Prog:   $(isempty(s.prog_name) ? "---" : s.prog_name)
Ver:    $(isempty(s.version)   ? "---" : s.version)
File:   $(basename(app.log_filename))"""
    end

    rowsize!(right, 1, Fixed(28))
    rowsize!(right, 2, Relative(0.28))

    # ── Flow path schematic ───────────────────────────────────────────────────
    ax_flow = Axis(right[3, 1];
        title="Flow Path", titlesize=12, aspect=nothing,
        xticksvisible=false, yticksvisible=false,
        xticklabelsvisible=false, yticklabelsvisible=false,
        leftspinevisible=false, rightspinevisible=false,
        topspinevisible=false, bottomspinevisible=false,
        limits=(0, 10, 0, 9))

    _draw_flow_schematic!(ax_flow, app)

    # Populate all on(app.inst) callbacks (status text + flow schematic) now
    # that every listener has been registered.
    notify(app.inst)

    # ── Auto-rescale axes on every data update ────────────────────────────────
    # Makie only runs reset_limits! once at display time; we must re-trigger it.
    # reset_limits! is a no-op when the user has manually zoomed (limits ≠ nothing).
    on(app.trend_data) do _
        reset_limits!(ax_uv)
        reset_limits!(ax_cond)
        reset_limits!(ax_pres)
        # ax_pctb y is fixed; its x updates via linkxaxes!
    end

    return fig
end

# ─────────────────────────────────────────────────────────────────────────────
# _draw_flow_schematic!
#
# Canvas x 0–10, y 0–9.  Main flow spine at y = 4.5.
#
#  BufA (1,7.5) ─┐
#                 ├─ MIXER(2.8) ─ PUMP(4.1) ─ INJ(5.5) ─ COL(6.8) ─ DET(8.1) ─┬─ FRAC(9.2,7.3)
#  BufB (1,1.5) ─┘                              │                               └─ WASTE
#                                             LOOP(3.0)
# ─────────────────────────────────────────────────────────────────────────────
function _draw_flow_schematic!(ax, app::AppState)
    function box!(ax, cx, cy, w, h, label; color=:lightblue, fontsize=9)
        poly!(ax, Rect2f(cx - w/2, cy - h/2, w, h);
              color=color, strokecolor=:black, strokewidth=1)
        text!(ax, cx, cy; text=label, fontsize=fontsize,
              align=(:center, :center), font=:bold)
    end

    # ── Flow lines ────────────────────────────────────────────────────────────
    lines!(ax, [1.0, 1.0, 1.8], [7.2, 4.5, 4.5]; color=COL_BUF_A, linewidth=2.0)
    lines!(ax, [1.0, 1.0, 1.8], [1.8, 4.5, 4.5]; color=COL_BUF_B, linewidth=2.0)
    lines!(ax, [1.8, 9.2],      [4.5, 4.5];       color=:steelblue, linewidth=2.5)

    # Sample loop off inject valve (dashed U)
    lines!(ax, [5.3, 5.3, 5.7, 5.7], [4.2, 3.0, 3.0, 4.2];
           color=:gray60, linewidth=1.5, linestyle=:dash)

    # Output: FRAC up, WASTE down (dashed)
    lines!(ax, [9.2, 9.2], [4.5, 7.0]; color=:steelblue, linewidth=2.0)
    lines!(ax, [9.2, 9.2], [4.5, 2.2]; color=:gray60, linewidth=1.5, linestyle=:dash)

    # ── Static boxes ─────────────────────────────────────────────────────────
    box!(ax, 1.0, 7.5, 0.75, 0.55, "BufA"; color=(COL_BUF_A, 0.75))
    box!(ax, 1.0, 1.5, 0.75, 0.55, "BufB"; color=(COL_BUF_B, 0.75))
    box!(ax, 4.1, 4.5, 0.90, 0.62, "PUMP"; color=(:skyblue,     0.90))
    box!(ax, 6.8, 4.5, 0.90, 0.62, "COL";  color=(:wheat,       0.90))
    box!(ax, 8.1, 4.5, 1.10, 0.65, "UV\nCOND"; color=(:lightyellow, 0.90), fontsize=8)
    box!(ax, 9.2, 7.3, 0.80, 0.55, "FRAC"; color=(:lightgreen,  0.85))
    text!(ax, 9.2, 2.0; text="WASTE", fontsize=8, color=:gray50, align=(:center, :center))
    text!(ax, 5.5, 2.7; text="loop",  fontsize=8, color=:gray50, align=(:center, :center))

    # ── MIXER — colour blends BufA→BufB by %B ────────────────────────────────
    mixer_color = @lift begin
        td = $(app.trend_data)
        f  = isempty(td) ? 0.0 : clamp(td[end].pctb / 100.0, 0.0, 1.0)
        RGBAf((1-f)*COL_BUF_A.r + f*COL_BUF_B.r,
              (1-f)*COL_BUF_A.g + f*COL_BUF_B.g,
              (1-f)*COL_BUF_A.b + f*COL_BUF_B.b, 0.9)
    end
    poly!(ax, Rect2f(2.8 - 0.55, 4.5 - 0.33, 1.10, 0.66);
          color=mixer_color, strokecolor=:black, strokewidth=1)
    mixer_label = @lift begin
        td = $(app.trend_data)
        isempty(td) ? "MIX" : @sprintf("%.0f%%B", td[end].pctb)
    end
    text!(ax, 2.8, 4.5; text=mixer_label, fontsize=8,
          align=(:center, :center), font=:bold)

    # ── INJ valve — load / inject (WASTE position: needs further protocol work)
    # Use explicit on() rather than @lift to guarantee the reactive chain
    # is never broken by a GC cycle on the intermediate Observable.
    inj_poly = poly!(ax, Rect2f(5.5 - 0.50, 4.5 - 0.33, 1.00, 0.66);
                     color=(:lightgray, 0.95), strokecolor=:black, strokewidth=1)
    inj_txt  = text!(ax, 5.5, 4.5; text="LOAD\n○", fontsize=8,
                     align=(:center, :center), font=:bold)
    on(app.inst) do s
        inj_poly.color[] = s.inject_active ? (:orchid, 0.95) : (:lightgray, 0.95)
        inj_txt.text[]   = s.inject_active ? "INJ\n●"        : "LOAD\n○"
    end

    # ── Run-state banner ──────────────────────────────────────────────────────
    state_text  = @lift $(app.inst).run_state
    state_color = @lift begin
        s = $(app.inst).run_state
        s == "Run"      ? (:green,  1.0) :
        s == "Pause"    ? (:orange, 1.0) :
        s == "Hold"     ? (:orange, 1.0) :
        s == "Continue" ? (:blue,   1.0) :
        s == "End"      ? (:red,    1.0) : (:gray, 1.0)
    end
    text!(ax, 5.0, 8.5; text=state_text, fontsize=14, font=:bold,
          align=(:center, :center), color=state_color)
end
