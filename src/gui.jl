# gui.jl — GLMakie real-time chromatography display

# ── Colour palette ────────────────────────────────────────────────────────────
const COL_UV = RGBf(0.15, 0.35, 0.70)
const COL_COND = RGBf(0.80, 0.20, 0.10)
const COL_PCTB = RGBf(0.10, 0.55, 0.25)
const COL_PRES = RGBf(0.75, 0.45, 0.00)

const COL_BUF_A = RGBf(0.80, 0.10, 0.10)   # red
const COL_BUF_B = RGBf(0.90, 0.80, 0.05)   # yellow

const EVT_COLORS = Dict(
    EVT_INJECT => (:purple, :dash),
    EVT_RUN_STATE => (:gray50, :dash),
    EVT_STEP => (:teal, :dashdot),
    EVT_TUBEFEED => (:brown, :dot),
    EVT_LOG => (:gray70, :dot),
    EVT_CONNECT => (:green, :solid),
    EVT_DISCONNECT => (:red, :solid),
)

_inject_label(v::InjectValue) =
    v == IV_LOAD ? "LOAD" :
    v == IV_INJECT ? "INJECT" :
    v == IV_WASTE ? "WASTE" : "UNKNOWN"

# ─────────────────────────────────────────────────────────────────────────────
# build_gui — construct the Figure and wire all Observables
# ─────────────────────────────────────────────────────────────────────────────
function build_gui(app::AppState)::Figure
    fig = Figure(size=(1440, 900), backgroundcolor=:white)

    # Two independent sub-layouts: plots left, status+flow right.
    # Nesting gives each side its own row-size control.
    left = fig[1, 1] = GridLayout()
    right = fig[1, 2] = GridLayout()
    colsize!(fig.layout, 1, Relative(0.72))
    colsize!(fig.layout, 2, Relative(0.28))

    # ── Chromatogram axes ─────────────────────────────────────────────────────
    ax_uv = Axis(left[1, 1]; ylabel="UV (AU)", xticklabelsvisible=false,
        ygridvisible=true, xgridvisible=false)
    ax_cond = Axis(left[2, 1]; ylabel="Cond (mS/cm)", xticklabelsvisible=false,
        ygridvisible=true, xgridvisible=false)
    ax_pctb = Axis(left[3, 1]; ylabel="%B", xticklabelsvisible=false,
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
    _trend = @lift let d = $(app.trend_data)
        isempty(d) ? [TrendPoint(0.0, 0.0, 0.0, 0.0, Int32(0), 0.0, 0.0, 0.0)] : d
    end
    x_mode_is_vol = Observable(false)
    x_arr = @lift begin
        by_vol = $x_mode_is_vol
        [by_vol ? p.cum_vol_mL : p.cum_time_ms / 60_000 for p in $_trend]
    end
    uv_arr = @lift [p.uv for p in $_trend]
    cond_arr = @lift [p.cond_mScm for p in $_trend]
    pctb_arr = @lift [p.pctb for p in $_trend]
    pres_arr = @lift [p.pres for p in $_trend]

    lines!(ax_uv, x_arr, uv_arr, color=COL_UV, linewidth=1.5)
    lines!(ax_cond, x_arr, cond_arr, color=COL_COND, linewidth=1.5)
    lines!(ax_pctb, x_arr, pctb_arr, color=COL_PCTB, linewidth=1.5)
    lines!(ax_pres, x_arr, pres_arr, color=COL_PRES, linewidth=1.5)

    # ── Event vlines on UV panel ──────────────────────────────────────────────
    # xautolimits/yautolimits=false prevents Makie calling extrema on empty vectors.
    for kind in instances(EventKind)
        let kind = kind
            color, style = get(EVT_COLORS, kind, (:black, :dash))
            evts_k = @lift filter(e -> e.kind == kind, $(app.events))
            evt_x_k = @lift begin
                by_vol = $x_mode_is_vol
                [by_vol ? e.cum_vol_mL : e.cum_time_ms / 60_000 for e in $evts_k]
            end
            vlines!(ax_uv, evt_x_k; color=(color, 0.55), linestyle=style, linewidth=1.0,
                xautolimits=false, yautolimits=false)
        end
    end

    # ── Event legend ──────────────────────────────────────────────────────────
    legend_elements = [LineElement(color=EVT_COLORS[k][1], linestyle=EVT_COLORS[k][2])
                       for k in (EVT_INJECT, EVT_RUN_STATE, EVT_STEP, EVT_LOG)]
    legend_labels = ["Inject", "State", "Step", "Log"]
    Legend(left[5, 1], legend_elements, legend_labels;
        orientation=:horizontal, framevisible=false, tellwidth=false,
        labelsize=11, patchsize=(18, 2))

    # ── Status panel + x-axis mode controls ─────────────────────────────────
    top_right = right[1, 1] = GridLayout()
    Label(top_right[1, 1], "INSTRUMENT STATUS";
        halign=:left, fontsize=12, font=:bold,
        tellwidth=false, padding=(8, 0, 4, 0))

    status_text = Observable("")
    Label(top_right[2, 1], status_text;
        halign=:left, valign=:top, tellwidth=false, tellheight=false,
        fontsize=11, padding=(8, 8, 0, 0))

    on(app.inst) do s
        inj = _inject_label(s.inject_value)
        route = s.fraction_vol_mL > 0 ? "FRAC #$(s.fraction_number)" : "WASTE"
        t_s = @sprintf("%.1f", s.run_time_ms / 1000)
        v = @sprintf("%.4f", s.run_vol_mL)
        status_text[] = """
State:  $(rpad(s.run_state, 10))  Valve: $inj
Run t:  $t_s s
Run v:  $v mL
Frac #: $(s.fraction_number)   Frac vol: $(@sprintf("%.2f", s.fraction_vol_mL)) mL
Out:    $route
Prog:   $(isempty(s.prog_name) ? "---" : s.prog_name)
Ver:    $(isempty(s.version)   ? "---" : s.version)
File:   $(basename(app.log_filename))"""
    end

    rowsize!(top_right, 1, Fixed(24))
    rowsize!(top_right, 2, Relative(1.0))
    rowsize!(right, 1, Fixed(180))

    # ── X-axis mode toggle (time vs volume) ─────────────────────────────────
    mode_grid = top_right[3, 1] = GridLayout()
    Label(mode_grid[1, 1], "X Axis"; halign=:left, fontsize=11, padding=(8, 0, 0, 0))
    mode_toggle = Toggle(mode_grid[1, 2], active=false)
    mode_label = @lift $(mode_toggle.active) ? "Volume (mL)" : "Time (min)"
    Label(mode_grid[1, 3], mode_label; halign=:left, fontsize=11)
    colsize!(mode_grid, 1, Relative(0.28))
    colsize!(mode_grid, 2, Fixed(34))
    colsize!(mode_grid, 3, Relative(0.72))

    on(mode_toggle.active) do by_vol
        x_mode_is_vol[] = by_vol
        ax_pres.xlabel[] = by_vol ? "Volume (mL)" : "Time (min)"
        if !app.iszoomed[]
            autolimits!(ax_uv)
            autolimits!(ax_cond)
            xautolimits!(ax_pctb)
            autolimits!(ax_pres)
        end
    end

    # ── Flow path schematic (expanded to rows 2:4) ──────────────────────────
    ax_flow = Axis(right[2:4, 1];
        title="Flow Path", titlesize=12, aspect=nothing,
        xgridvisible=false, ygridvisible=false,
        xticksvisible=false, yticksvisible=false,
        xticklabelsvisible=false, yticklabelsvisible=false,
        leftspinevisible=false, rightspinevisible=false,
        topspinevisible=false, bottomspinevisible=false,
        limits=(0, 10, 0, 12))

    _draw_flow_schematic!(ax_flow, app)

    # Populate all on(app.inst) callbacks (status text + flow schematic) now
    # that every listener has been registered.
    notify(app.inst)

    # ── Zoom/pan tracking and auto-limit policy ───────────────────────────────
    app.iszoomed[] = false
    axes = (ax_uv, ax_cond, ax_pctb, ax_pres)
    _is_manual_limits(lims) = !isnothing(lims) && lims != (nothing, nothing)

    for ax in axes
        on(ax.limits) do lims
            if isnothing(lims) || lims == (nothing, nothing)
                app.iszoomed[] = false
                autolimits!(ax_uv)
                autolimits!(ax_cond)
                xautolimits!(ax_pctb)
                autolimits!(ax_pres)
            end
        end

        on(ax.finallimits) do _
            if _is_manual_limits(ax.limits[])
                app.iszoomed[] = true
            end
        end
    end

    on(app.trend_data) do _
        if !app.iszoomed[]
            autolimits!(ax_uv)
            autolimits!(ax_cond)
            xautolimits!(ax_pctb)
            autolimits!(ax_pres)
        end
    end

    return fig
end

# ─────────────────────────────────────────────────────────────────────────────
function _draw_flow_schematic!(ax, app::AppState)
    function box!(ax, cx, cy, w, h, label; color=:lightblue, fontsize=9)
        poly!(ax, Rect2f(cx - w / 2, cy - h / 2, w, h);
            color=color, strokecolor=:black, strokewidth=1)
        text!(ax, cx, cy; text=label, fontsize=fontsize,
            align=(:center, :center), font=:bold)
    end

    function diamond!(ax, cx, cy, w, h; color=:lightgray)
        verts = Point2f[
            (cx, cy + h / 2),
            (cx + w / 2, cy),
            (cx, cy - h / 2),
            (cx - w / 2, cy),
        ]
        poly!(ax, verts; color=color, strokecolor=:black, strokewidth=1)
    end

    setvisible!(ln, active) = (ln.visible[] = active)

    # ── Node coordinates (staggered vertically for readability) ─────────────
    x_l, x_c, x_r = 2.2, 4.2, 7.1
    x_frac = x_r

    y_buf = 11.3
    y_mix = 10.3
    y_syr = 9.4
    y_inj = 8.5
    y_loop = 7.6
    y_waste_inj = 7.6
    y_col = 6.6
    y_waste_loop = 5.8
    y_uv = 5.0
    y_out = 3.6
    y_bottom = 2.4

    # Geometry chosen to mirror the requested routing diagrams.
    ln_buf_a = lines!(ax, [x_l, x_c], [11.0, y_mix + 0.02]; color=COL_BUF_A, linewidth=2.2, visible=false)
    ln_buf_b = lines!(ax, [x_frac, x_c], [11.0, y_mix + 0.02]; color=COL_BUF_B, linewidth=2.2, visible=false)
    ln_mix_to_valve = lines!(ax, [x_c, x_c], [y_mix - 0.38, y_inj + 0.42]; color=:steelblue, linewidth=2.5, visible=false)

    # ── Switchable paths (inject + syringe + output valve) ──────────────────
    ln_load_core = lines!(ax, [x_c, x_c], [y_inj - 0.42, y_col + 0.42]; color=:steelblue, linewidth=2.7, visible=false)
    ln_inj_to_loop = lines!(ax, [x_c, x_r], [y_inj, y_loop]; color=:steelblue, linewidth=2.7, visible=false)
    ln_inj_return = lines!(ax, [x_r, x_c], [y_loop, y_col]; color=:steelblue, linewidth=2.7, visible=false)
    ln_waste_byp = lines!(ax, [x_c, x_l], [y_inj, y_waste_inj]; color=:steelblue, linewidth=2.7, visible=false)

    ln_syr_to_loop = lines!(ax, [x_r, x_r], [y_syr - 0.34, y_loop + 0.34]; color=:orangered3, linewidth=2.1, visible=false)
    ln_loop_waste = lines!(ax, [x_r, x_r], [y_loop - 0.34, y_waste_loop + 0.34]; color=:orangered3, linewidth=2.1, visible=false)

    ln_col_to_uv = lines!(ax, [x_c, x_c], [y_col - 0.42, y_uv + 0.42]; color=:steelblue, linewidth=2.5, visible=false)
    ln_uv_to_out = lines!(ax, [x_c, x_c], [y_uv - 0.42, y_out + 0.40]; color=:steelblue, linewidth=2.5, visible=false)
    ln_out_waste = lines!(ax, [x_c, x_l], [y_out, y_bottom]; color=:steelblue, linewidth=2.4, visible=false)
    ln_out_frac = lines!(ax, [x_c, x_frac], [y_out, y_bottom]; color=:steelblue, linewidth=2.4, visible=false)

    # ── Static symbols ───────────────────────────────────────────────────────
    box!(ax, x_l, y_buf, 1.30, 0.62, "Buffer A"; color=(COL_BUF_A, 0.78), fontsize=8)
    box!(ax, x_frac, y_buf, 1.30, 0.62, "Buffer B"; color=(COL_BUF_B, 0.78), fontsize=8)
    box!(ax, x_c, y_mix, 1.30, 0.72, "MIX"; color=(:khaki1, 0.94), fontsize=8)
    inj_poly = diamond!(ax, x_c, y_inj, 1.55, 0.92; color=(:lightgray, 0.94))
    box!(ax, x_c, y_col, 1.35, 0.74, "COLUMN"; color=(:wheat, 0.93), fontsize=8)
    box!(ax, x_c, y_uv, 1.48, 0.78, "UV / COND"; color=(:lightyellow, 0.93), fontsize=8)
    out_poly = diamond!(ax, x_c, y_out, 1.30, 0.84; color=(:azure2, 0.93))
    box!(ax, x_r, y_syr, 1.45, 0.62, "SYRINGE"; color=(:mistyrose2, 0.88), fontsize=8)
    box!(ax, x_r, y_loop, 1.20, 0.62, "LOOP"; color=(:gray95, 0.93), fontsize=8)
    box!(ax, x_frac, y_bottom, 1.25, 0.68, "FRAC"; color=(:lightgreen, 0.90), fontsize=8)
    box!(ax, x_l, y_bottom, 1.30, 0.62, "WASTE"; color=(:gray92, 0.95), fontsize=8)
    box!(ax, x_r, y_waste_loop, 1.30, 0.62, "WASTE"; color=(:gray92, 0.95), fontsize=8)
    box!(ax, x_l, y_waste_inj, 1.30, 0.62, "WASTE"; color=(:gray92, 0.95), fontsize=8)

    # ── MIXER — colour blends BufA→BufB by %B ────────────────────────────────
    mixer_color = @lift begin
        td = $(app.trend_data)
        f = isempty(td) ? 0.0 : clamp(td[end].pctb / 100.0, 0.0, 1.0)
        RGBAf((1 - f) * COL_BUF_A.r + f * COL_BUF_B.r,
            (1 - f) * COL_BUF_A.g + f * COL_BUF_B.g,
            (1 - f) * COL_BUF_A.b + f * COL_BUF_B.b, 0.9)
    end
    poly!(ax, Rect2f(x_c - 0.65, y_mix - 0.36, 1.30, 0.72);
        color=mixer_color, strokecolor=:black, strokewidth=1)
    mixer_label = @lift begin
        td = $(app.trend_data)
        isempty(td) ? "MIX" : @sprintf("%.0f%%B", td[end].pctb)
    end
    text!(ax, x_c, y_mix; text=mixer_label, fontsize=8,
        align=(:center, :center), font=:bold)

    inj_txt = text!(ax, x_c, y_inj; text="LOAD", fontsize=8,
        align=(:center, :center), font=:bold, color=:black)
    text!(ax, x_c, y_out; text="OUT", fontsize=8,
        align=(:center, :center), font=:bold, color=:black)
    out_txt = text!(ax, x_c, y_out - 0.95; text="TO WASTE", fontsize=8,
        align=(:center, :center), font=:bold, color=:gray35)

    on(app.inst) do s
        is_load = s.inject_value == IV_LOAD
        is_inj = s.inject_value == IV_INJECT
        is_wst = s.inject_value == IV_WASTE
        is_unk = s.inject_value == IV_UNKNOWN

        has_known_path = !is_unk
        setvisible!(ln_buf_a, has_known_path)
        setvisible!(ln_buf_b, has_known_path)
        setvisible!(ln_mix_to_valve, has_known_path)

        setvisible!(ln_load_core, has_known_path && is_load)
        setvisible!(ln_inj_to_loop, has_known_path && is_inj)
        setvisible!(ln_inj_return, has_known_path && is_inj)
        setvisible!(ln_waste_byp, has_known_path && is_wst)

        setvisible!(ln_syr_to_loop, has_known_path && is_load)
        setvisible!(ln_loop_waste, has_known_path && is_load)

        to_column = has_known_path && (is_load || is_inj)
        setvisible!(ln_col_to_uv, to_column)
        setvisible!(ln_uv_to_out, to_column)

        out_to_frac = s.fraction_vol_mL > 0
        setvisible!(ln_out_frac, has_known_path && out_to_frac)
        setvisible!(ln_out_waste, has_known_path && !out_to_frac)

        inj_poly.color[] = is_unk ? (:red, 0.95) : (:lightgray, 0.94)
        out_poly.color[] = (:azure2, 0.93)

        inj_txt.text[] = _inject_label(s.inject_value)
        out_txt.text[] = is_unk ? "PATH UNKNOWN" :
                         (out_to_frac ? "TO FRAC #$(s.fraction_number)" : "TO WASTE")
    end

    # ── Run-state banner ──────────────────────────────────────────────────────
    state_text = @lift $(app.inst).run_state
    state_color = @lift begin
        s = $(app.inst).run_state
        s == "Run" ? (:green, 1.0) :
        s == "Pause" ? (:orange, 1.0) :
        s == "Hold" ? (:orange, 1.0) :
        s == "Continue" ? (:blue, 1.0) :
        s == "End" ? (:red, 1.0) : (:gray, 1.0)
    end
    text!(ax, 1.6, 10.6; text=state_text, fontsize=12, font=:bold,
        align=(:center, :center), color=state_color)
end
