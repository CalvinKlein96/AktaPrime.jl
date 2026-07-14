# gui.jl — GLMakie real-time chromatography display

# ── Colour palette ────────────────────────────────────────────────────────────
const COL_UV = RGBf(0.15, 0.35, 0.70)
const COL_COND = RGBf(0.80, 0.20, 0.10)
const COL_PCTB = RGBf(0.10, 0.55, 0.25)
const COL_PRES = RGBf(0.75, 0.45, 0.00)
const COL_PH = RGBf(0.55, 0.25, 0.65)

const COL_BUF_A = RGBf(0.80, 0.10, 0.10)   # red
const COL_BUF_B = RGBf(0.90, 0.80, 0.05)   # yellow

const FRAC_COLORS = [RGBf(0.8, 0.9, 1.0), RGBf(1.0, 1.0, 0.8)]  # light blue, light yellow
const FRAC_ALPHA = 0.22

const EVT_COLORS = Dict(
    EVT_INJECT => (:hotpink, :solid),
    EVT_RUN_STATE => (:green, :dash),
    EVT_STEP => (:teal, :dashdot),
    EVT_TUBEFEED => (:grey50, :solid),
    EVT_LOG => (:blue, :solid),
    EVT_CONNECT => (:green, :solid),
    EVT_DISCONNECT => (:red, :solid),
)

_inject_label(v::InjectValue) =
    v == IV_LOAD ? "LOAD" :
    v == IV_INJECT ? "INJECT" :
    v == IV_WASTE ? "WASTE" : "UNKNOWN"

function _event_label_top(e::AktaEvent)::String
    if e.kind == EVT_INJECT
        if (m = match(r"Valve\s*→\s*([A-Za-z_]+)", e.text)) !== nothing
            return "INJ $(uppercase(m.captures[1]))"
        end
        return "INJECT"
    elseif e.kind == EVT_RUN_STATE
        if (m = match(r"Run state:\s*([^\s]+)", e.text)) !== nothing
            return "STATE $(uppercase(m.captures[1]))"
        end
        return "STATE"
    elseif e.kind == EVT_STEP
        return "STEP"
    elseif e.kind == EVT_LOG
        # Special handling for fraction size zero-transitions
        if contains(e.text, "Fraction size")
            if (m = match(r"Fraction size (\d+(?:\.\d+)?)", e.text)) !== nothing
                val = parse(Float64, m.captures[1])
                return val > 0.0 ? "FRAC START" : "FRAC STOP"
            end
        end
        return length(e.text) > 18 ? "LOG $(e.text[1:15])..." : "LOG $(e.text)"
    elseif e.kind == EVT_CONNECT
        return "CONNECT"
    elseif e.kind == EVT_DISCONNECT
        return "DISCONNECT"
    end
    return string(e.kind)
end

_trend_x(p::TrendPoint, by_vol::Bool)::Float32 =
    by_vol ? Float32(p.cum_vol_mL) : Float32(p.cum_time_ms / 60_000)

_event_x(e::AktaEvent, by_vol::Bool)::Float32 =
    by_vol ? Float32(e.cum_vol_mL) : Float32(e.cum_time_ms / 60_000)

function _fraction_label_bottom(e::AktaEvent)::String
    # Show just the fraction number (no "F#" prefix)
    if (m = match(r"Feed Tube Nr\s+(\d+)", e.text)) !== nothing
        return m.captures[1]  # Plain number only
    end
    return "?"
end

# ─────────────────────────────────────────────────────────────────────────────
# build_gui — construct the Figure and wire all Observables
# ─────────────────────────────────────────────────────────────────────────────
function build_gui(app::AppState; viewer::Bool=false)::Figure
    fig = Figure(size=(1440, 900), backgroundcolor=:white)

    # Two independent sub-layouts: plots left, status+flow right.
    # Nesting gives each side its own row-size control.
    left = fig[1, 1] = GridLayout()
    right = fig[1, 2] = GridLayout(; valign=:top)
    colsize!(fig.layout, 1, Relative(0.75))
    colsize!(fig.layout, 2, Relative(0.25))
    # Force the single row to fill the figure height. Without this, in viewer
    # mode (where the right column has no height-filling flow schematic) the row
    # would shrink to the right column's content and squash the plots.
    rowsize!(fig.layout, 1, Relative(1))

    x_mode_is_vol = Observable(false)

    # ── Chromatogram axes (UV always shown; the rest are toggleable) ───────────
    ax_uv = Axis(left[1, 1]; ylabel="UV (AU)", ygridvisible=false, xgridvisible=false)
    ax_pctb = Axis(left[2, 1]; ylabel="%B", ygridvisible=false, xgridvisible=false,
        limits=(nothing, (-3, 103)))   # margin so the trace is visible at 0 %B and 100 %B
    ax_cond = Axis(left[3, 1]; ylabel="Conductivity (mS/cm)",
        ygridvisible=false, xgridvisible=false)
    ax_ph = Axis(left[4, 1]; ylabel="pH", ygridvisible=false, xgridvisible=false)
    ax_pres = Axis(left[5, 1]; ylabel="Pressure (MPa)",
        ygridvisible=false, xgridvisible=false)

    linkxaxes!(ax_uv, ax_pctb, ax_cond, ax_ph, ax_pres)

    # x label tracks the plotting mode; per-panel visibility is set by
    # refresh_panels! below so only the lowest visible panel carries it.
    for ax in (ax_uv, ax_pctb, ax_cond, ax_ph, ax_pres)
        ax.xlabel = "Time (min)"
        ax.xticklabelsvisible = false
        ax.xlabelvisible = false
    end

    # ── Data observables ──────────────────────────────────────────────────────
    # Guard: provide a dummy point when empty so GLMakie axis autoscaling
    # never reduces over an empty collection on first render.
    _trend = @lift let d = $(app.trend_data)
        isempty(d) ? [TrendPoint(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)] : d
    end
    uv_pts = @lift [Point2f(_trend_x(p, $x_mode_is_vol), p.uv) for p in $_trend]
    cond_pts = @lift [Point2f(_trend_x(p, $x_mode_is_vol), p.cond_mScm) for p in $_trend]
    ph_pts = @lift [Point2f(_trend_x(p, $x_mode_is_vol), p.ph) for p in $_trend]
    pctb_pts = @lift [Point2f(_trend_x(p, $x_mode_is_vol), p.pctb) for p in $_trend]
    pres_pts = @lift [Point2f(_trend_x(p, $x_mode_is_vol), p.pres_MPa) for p in $_trend]

    lines!(ax_uv, uv_pts, color=COL_UV, linewidth=1.5)
    pl_pctb = lines!(ax_pctb, pctb_pts, color=COL_PCTB, linewidth=1.5)
    pl_cond = lines!(ax_cond, cond_pts, color=COL_COND, linewidth=1.5)
    pl_ph = lines!(ax_ph, ph_pts, color=COL_PH, linewidth=1.5)
    pl_pres = lines!(ax_pres, pres_pts, color=COL_PRES, linewidth=1.5)

    # ── Event vlines on UV panel ──────────────────────────────────────────────
    # xautolimits/yautolimits=false prevents Makie calling extrema on empty vectors.
    for kind in instances(EventKind)
        let kind = kind
            color, style = get(EVT_COLORS, kind, (:black, :dash))
            evts_k = @lift filter(e -> e.kind == kind, $(app.events))
            evt_x_k = @lift [_event_x(e, $x_mode_is_vol) for e in $evts_k]
            vlines!(ax_uv, evt_x_k; color=(color, 0.55), linestyle=style, linewidth=1.0,
                xautolimits=false, yautolimits=false)
        end
    end

    # ── Fraction collection spans on UV and %B panels ──────────────────────────
    # Build starts/ends/colors from one observable to keep lengths in lockstep.
    fraction_spans = @lift begin
        fracs = $(app.fractions)
        by_vol = $x_mode_is_vol

        starts = Float64[]
        ends = Float64[]
        colors = RGBf[]
        label_pts = Point2f[]
        labels = String[]

        for (i, f) in enumerate(fracs)
            x0 = by_vol ? f.start_vol_mL : f.start_time_ms / 60_000
            x1 = if !isnothing(f.end_time_ms) && !isnothing(f.end_vol_mL)
                by_vol ? something(f.end_vol_mL) : something(f.end_time_ms) / 60_000
            elseif !isempty($_trend)
                p = $_trend[end]
                by_vol ? p.cum_vol_mL : p.cum_time_ms / 60_000
            else
                x0
            end

            if x1 > x0
                push!(starts, x0)
                push!(ends, x1)
                push!(colors, FRAC_COLORS[mod1(i, length(FRAC_COLORS))])
                push!(label_pts, Point2f((x0 + x1) / 2, 1.0f0))
                push!(labels, string(f.fraction_number))
            end
        end

        (starts, ends, colors, label_pts, labels)
    end

    frac_xstart = @lift $fraction_spans[1]
    frac_xend = @lift $fraction_spans[2]
    frac_colors = @lift $fraction_spans[3]
    frac_label_pts = @lift $fraction_spans[4]
    frac_labels = @lift $fraction_spans[5]

    vspan!(ax_uv, frac_xstart, frac_xend;
        color=frac_colors, alpha=FRAC_ALPHA, xautolimits=false, yautolimits=false)
    vspan!(ax_pctb, frac_xstart, frac_xend;
        color=frac_colors, alpha=FRAC_ALPHA, xautolimits=false, yautolimits=false)

    # Fraction number labels in %B panel near baseline (0%)
    text!(ax_pctb, frac_label_pts;
        text=frac_labels, fontsize=12, color=:blue,
        font=:bold, align=(:center, :bottom),
        xautolimits=false, yautolimits=false)

    # ── Other event text labels on UV panel ────────────────────────────────────
    # Filter other events, keeping only the non-tube-feed events (and zero-transition fraction size changes)
    evt_other = @lift begin
        events = $(app.events)
        # Track fraction volume state to detect zero-transitions
        frac_vol_states = Float64[]
        for e in events
            if e.kind == EVT_LOG && contains(e.text, "Fraction size")
                if (m = match(r"Fraction size (\d+(?:\.\d+)?)", e.text)) !== nothing
                    push!(frac_vol_states, parse(Float64, m.captures[1]))
                end
            end
        end

        # Collect filtered events: exclude tube-feeds, keep zero-transition fraction-size events
        filtered = AktaEvent[]
        frac_vol_prev = 0.0
        frac_vol_idx = 0
        for e in events
            if e.kind == EVT_TUBEFEED
                continue  # Shown as vspans instead
            elseif e.kind == EVT_LOG && contains(e.text, "Fraction size")
                frac_vol_idx += 1
                frac_vol_current = frac_vol_idx <= length(frac_vol_states) ? frac_vol_states[frac_vol_idx] : 0.0
                # Show only on zero-transitions: 0→>0 or >0→0
                if (frac_vol_prev == 0.0 && frac_vol_current > 0.0) || (frac_vol_prev > 0.0 && frac_vol_current == 0.0)
                    push!(filtered, e)
                end
                frac_vol_prev = frac_vol_current
            else
                push!(filtered, e)
            end
        end
        filtered
    end

    uv_text_top_y = @lift begin
        yvals = [p[2] for p in $uv_pts]
        ymax = maximum(yvals)
        span = max(1e-6, ymax - minimum(yvals))
        ymax - 0.05 * span
    end

    evt_top_pts = @lift [Point2f(_event_x(e, $x_mode_is_vol), $uv_text_top_y) for e in $evt_other]
    evt_top_lbl = @lift [_event_label_top(e) for e in $evt_other]

    text!(ax_uv, evt_top_pts;
        text=evt_top_lbl, fontsize=8, color=:gray25,
        align=(:center, :top), xautolimits=false, yautolimits=false)

    # ── Event legend ──────────────────────────────────────────────────────────
    # legend_elements = [LineElement(color=EVT_COLORS[k][1], linestyle=EVT_COLORS[k][2])
    #                    for k in (EVT_INJECT, EVT_RUN_STATE, EVT_STEP, EVT_LOG)]
    # legend_labels = ["Inject", "State", "Step", "Log"]
    # Legend(left[5, 1], legend_elements, legend_labels;
    #     orientation=:horizontal, framevisible=false, tellwidth=false,
    #     labelsize=11, patchsize=(18, 2))

    # ── Right panel: title, controls, toggles, status, (flow schematic) ────────
    Label(right[1, 1], "AktaPrime.jl (v0.1.0)";
        halign=:center, fontsize=17, font=:bold, tellwidth=false)

    # Controls: plotting-mode menu (left) + save-plot button (right)
    controls = right[2, 1] = GridLayout(; tellwidth=false)
    xmenu = Menu(controls[1, 1];
        options=["Plot vs time", "Plot vs volume"],
        default="Plot vs time", tellwidth=false, fontsize=13)
    save_btn = Button(controls[1, 2]; label="Save plot…", fontsize=13)
    colgap!(controls, 8)

    # ── 2×2 chart-visibility toggles ───────────────────────────────────────────
    toggle_grid = right[3, 1] = GridLayout(; tellwidth=false, halign=:center)
    Label(toggle_grid[1, 1], "%B"; halign=:right, fontsize=13)
    tg_pctb = Toggle(toggle_grid[1, 2], active=true)
    Label(toggle_grid[1, 3], "Cond"; halign=:right, fontsize=13)
    tg_cond = Toggle(toggle_grid[1, 4], active=true)
    Label(toggle_grid[2, 1], "pH"; halign=:right, fontsize=13)
    tg_ph = Toggle(toggle_grid[2, 2], active=true)
    Label(toggle_grid[2, 3], "Pressure"; halign=:right, fontsize=13)
    tg_pres = Toggle(toggle_grid[2, 4], active=true)
    colgap!(toggle_grid, 6)

    # Zoom hint above the status read-out
    Label(right[4, 1], "Drag to zoom · Right-drag to pan · Ctrl-click to reset";
        halign=:center, valign=:center, tellwidth=false, fontsize=11, color=:gray40)

    # ── Status read-out — left-aligned text ────────────────────────────────────
    status_text = Observable("")
    Label(right[5, 1], status_text;
        halign=:left, justification=:left, tellwidth=false, fontsize=13)

    if viewer
        # Viewer/replay mode: no live instrument state — just show the file.
        status_text[] = "File:   $(basename(app.log_filename))"
    else
        on(app.inst) do s
            inj = lowercase(_inject_label(s.inject_value))
            route = s.fraction_vol_mL > 0 ? "frac collector" : "waste"
            t_min = @sprintf("%.2f", s.run_time_ms / 60_000)
            v = @sprintf("%.4f", s.run_vol_mL)
            status_text[] = """
State: $(s.run_state)
Run time: $t_min min
Run volume: $v mL
Valve: $inj
Output: $route
Fraction #: $(s.fraction_number)
Fraction volume: $(@sprintf("%.2f", s.fraction_vol_mL)) mL
File: $(basename(app.log_filename))"""
        end
    end

    # ── Flow path schematic (live mode only) ───────────────────────────────────
    if !viewer
        ax_flow = Axis(right[6, 1];
            xgridvisible=false, ygridvisible=false,
            xticksvisible=false, yticksvisible=false,
            xticklabelsvisible=false, yticklabelsvisible=false,
            leftspinevisible=false, rightspinevisible=false,
            topspinevisible=false, bottomspinevisible=false,
            limits=(0.3, 8.1, 1.3, 12.0))
        _draw_flow_schematic!(ax_flow, app)
    end

    # Full-extent autoscale of the shared x-axis and the free (non-%B) y-axes.
    rescale!() = (autolimits!(ax_uv); ylims!(ax_cond); ylims!(ax_ph); ylims!(ax_pres))

    # On switching time<->volume, relabel the x-axis and reset the limits to fit
    # the data in the new units (equivalent to a zoom reset). Live updates and
    # manual zooming continue to work normally afterwards.
    on(xmenu.selection) do sel
        by_vol = sel == "Plot vs volume"
        x_mode_is_vol[] = by_vol
        lbl = by_vol ? "Volume (mL)" : "Time (min)"
        for ax in (ax_uv, ax_pctb, ax_cond, ax_ph, ax_pres)
            ax.xlabel = lbl
        end
        rescale!()
    end

    # Save the currently displayed plot (visible panels, current limits) to PDF.
    fig_counter = Ref(0)
    on(save_btn.clicks) do _
        _save_plot_pdf(app, (ax_uv, ax_pctb, ax_cond, ax_ph, ax_pres),
            (tg_pctb, tg_cond, tg_ph, tg_pres), x_mode_is_vol[], fig_counter)
    end

    # ── Panel show/hide ─────────────────────────────────────────────────────────
    # Hiding a panel collapses its row *and* turns off its line and every
    # decoration, so no orphaned frame, ticks or labels are left behind.  UV is
    # always shown; the toggles drive the other four.  The lowest visible panel
    # carries the shared x tick labels and axis label.
    panels = ((ax_pctb, pl_pctb, 2, tg_pctb), (ax_cond, pl_cond, 3, tg_cond),
        (ax_ph, pl_ph, 4, tg_ph), (ax_pres, pl_pres, 5, tg_pres))

    function showaxis!(ax, vis)
        ax.ylabelvisible = vis
        ax.yticksvisible = vis
        ax.yticklabelsvisible = vis
        ax.ygridvisible = false   # no horizontal grid lines
        ax.xticksvisible = vis
        ax.leftspinevisible = vis
        ax.rightspinevisible = vis
        ax.topspinevisible = vis
        ax.bottomspinevisible = vis
        # x tick labels and the x axis label are re-enabled only on the bottom
        # visible panel, below.
        ax.xticklabelsvisible = false
        ax.xlabelvisible = false
    end

    function refresh_panels!()
        visible = Axis[ax_uv]
        showaxis!(ax_uv, true)
        rowsize!(left, 1, Auto())
        for (ax, pl, row, tg) in panels
            vis = tg.active[]
            pl.visible[] = vis
            showaxis!(ax, vis)
            rowsize!(left, row, vis ? Auto() : Fixed(0))
            vis && push!(visible, ax)
        end
        bottom = visible[end]
        bottom.xticklabelsvisible = true
        bottom.xlabelvisible = true
    end

    for (_, _, _, tg) in panels
        on(_ -> refresh_panels!(), tg.active)
    end
    refresh_panels!()

    # Populate all on(app.inst) callbacks (status text + flow schematic) now
    # that every listener has been registered.
    notify(app.inst)

    on(app.trend_data) do _
        rescale!()
    end

    return fig
end

# ─────────────────────────────────────────────────────────────────────────────
# Plot export helpers
# ─────────────────────────────────────────────────────────────────────────────

_channel_value(p::TrendPoint, chan::Symbol)::Float64 =
    chan === :uv ? p.uv :
    chan === :pctb ? p.pctb :
    chan === :cond ? p.cond_mScm :
    chan === :ph ? p.ph : p.pres_MPa

# Shade fraction-collection spans (and optionally number them) on a static axis.
function _draw_fraction_spans!(ax, fracs::Vector{Fraction}, trend::Vector{TrendPoint},
    by_vol::Bool; labels::Bool=false)
    isempty(fracs) && return
    lastx = isempty(trend) ? 0.0 :
            (by_vol ? trend[end].cum_vol_mL : trend[end].cum_time_ms / 60_000)
    starts = Float64[]
    ends = Float64[]
    cols = RGBf[]
    lblpts = Point2f[]
    lbls = String[]
    for (i, f) in enumerate(fracs)
        x0 = by_vol ? f.start_vol_mL : f.start_time_ms / 60_000
        x1 = if !isnothing(f.end_time_ms) && !isnothing(f.end_vol_mL)
            by_vol ? f.end_vol_mL : f.end_time_ms / 60_000
        else
            lastx
        end
        if x1 > x0
            push!(starts, x0)
            push!(ends, x1)
            push!(cols, FRAC_COLORS[mod1(i, length(FRAC_COLORS))])
            push!(lblpts, Point2f((x0 + x1) / 2, 1.0f0))
            push!(lbls, string(f.fraction_number))
        end
    end
    isempty(starts) && return
    vspan!(ax, starts, ends; color=cols, alpha=FRAC_ALPHA)
    labels && text!(ax, lblpts; text=lbls, fontsize=12, color=:blue,
        font=:bold, align=(:center, :bottom))
    return
end

# Render the currently displayed chromatogram (only the visible panels, with the
# current axis limits) to a PDF via CairoMakie.  Files are numbered per session:
# <prefix>_<date>_<time>_figure_N.pdf
function _save_plot_pdf(app::AppState, axes, toggles, by_vol::Bool, counter::Ref{Int})
    trend = copy(app.trend_data[])
    if isempty(trend)
        @warn "Nothing to save yet — no data on the plot"
        return
    end
    events = copy(app.events[])
    fracs = copy(app.fractions[])
    ax_uv, ax_pctb, ax_cond, ax_ph, ax_pres = axes
    tg_pctb, tg_cond, tg_ph, tg_pres = toggles

    # Visible panels top-to-bottom (UV always); keep the source axis for its y-limits.
    specs = Tuple{Axis,Symbol,String,RGBf}[(ax_uv, :uv, "UV (AU)", COL_UV)]
    tg_pctb.active[] && push!(specs, (ax_pctb, :pctb, "%B", COL_PCTB))
    tg_cond.active[] && push!(specs, (ax_cond, :cond, "Conductivity (mS/cm)", COL_COND))
    tg_ph.active[] && push!(specs, (ax_ph, :ph, "pH", COL_PH))
    tg_pres.active[] && push!(specs, (ax_pres, :pres, "Pressure (MPa)", COL_PRES))

    xr = ax_uv.finallimits[]
    xlo, xhi = xr.origin[1], xr.origin[1] + xr.widths[1]
    xlab = by_vol ? "Volume (mL)" : "Time (min)"

    expfig = Figure(size=(1000, 220 * length(specs)), backgroundcolor=:white)
    exaxes = Axis[]
    for (i, (srcax, chan, ylab, col)) in enumerate(specs)
        bottom = i == length(specs)
        ax = Axis(expfig[i, 1]; ylabel=ylab, xlabel=(bottom ? xlab : ""),
            xgridvisible=false, ygridvisible=false, xticklabelsvisible=bottom)
        (chan === :uv || chan === :pctb) &&
            _draw_fraction_spans!(ax, fracs, trend, by_vol; labels=(chan === :pctb))
        if chan === :uv
            for e in events
                c, style = get(EVT_COLORS, e.kind, (:black, :dash))
                vlines!(ax, [_event_x(e, by_vol)]; color=(c, 0.55), linestyle=style, linewidth=1.0)
            end
        end
        lines!(ax, [Point2f(_trend_x(p, by_vol), _channel_value(p, chan)) for p in trend];
            color=col, linewidth=1.5)
        yr = srcax.finallimits[]
        ylims!(ax, yr.origin[2], yr.origin[2] + yr.widths[2])
        push!(exaxes, ax)
    end
    linkxaxes!(exaxes...)
    xlims!(exaxes[1], xlo, xhi)

    counter[] += 1
    prefix = isempty(app.log_prefix) ? "akta" : app.log_prefix
    stamp = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
    path = "$(prefix)_$(stamp)_figure_$(counter[]).pdf"

    CairoMakie.activate!()
    try
        save(path, expfig)
        @info "Saved plot to $path"
    catch err
        @error "Could not save plot" exception = err
    finally
        GLMakie.activate!()
    end
    return
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
    x_l, x_c, x_r = 1.3, 4.2, 7.1
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

    ln_syr_to_loop = lines!(ax, [x_r, x_r], [y_syr - 0.34, y_loop + 0.34]; color=:steelblue, linewidth=2.1, visible=false)
    ln_loop_waste = lines!(ax, [x_r, x_r], [y_loop - 0.34, y_waste_loop + 0.34]; color=:steelblue, linewidth=2.1, visible=false)

    ln_col_to_uv = lines!(ax, [x_c, x_c], [y_col - 0.42, y_uv + 0.42]; color=:steelblue, linewidth=2.5, visible=false)
    ln_uv_to_out = lines!(ax, [x_c, x_c], [y_uv - 0.42, y_out + 0.40]; color=:steelblue, linewidth=2.5, visible=false)
    ln_out_waste = lines!(ax, [x_c, x_l], [y_out, y_bottom]; color=:gray45, linewidth=2.4, visible=false)
    ln_out_frac = lines!(ax, [x_c, x_frac], [y_out, y_bottom]; color=:forestgreen, linewidth=2.4, visible=false)

    # ── Static symbols ───────────────────────────────────────────────────────
    # The mixer box itself is drawn below as a live %B-coloured poly, so it is
    # deliberately omitted here to avoid a doubled label.
    box!(ax, x_l, y_buf, 1.30, 0.62, "Buffer A"; color=COL_BUF_A, fontsize=11)
    box!(ax, x_frac, y_buf, 1.30, 0.62, "Buffer B"; color=COL_BUF_B, fontsize=11)
    inj_poly = diamond!(ax, x_c, y_inj, 1.55, 0.92; color=:lightgray)
    box!(ax, x_c, y_col, 1.35, 0.74, "COLUMN"; color=:wheat, fontsize=11)
    box!(ax, x_c, y_uv, 1.48, 0.78, "UV / COND"; color=:lightyellow, fontsize=11)
    out_poly = diamond!(ax, x_c, y_out, 1.30, 0.84; color=:azure2)
    box!(ax, x_r, y_syr, 1.45, 0.62, "SYRINGE"; color=:mistyrose2, fontsize=11)
    box!(ax, x_r, y_loop, 1.20, 0.62, "LOOP"; color=:gray95, fontsize=11)
    box!(ax, x_frac, y_bottom, 1.25, 0.68, "FRAC"; color=:lightgreen, fontsize=11)
    box!(ax, x_l, y_bottom, 1.30, 0.62, "WASTE"; color=:gray92, fontsize=11)
    box!(ax, x_r, y_waste_loop, 1.30, 0.62, "WASTE"; color=:gray92, fontsize=11)
    box!(ax, x_l, y_waste_inj, 1.30, 0.62, "WASTE"; color=:gray92, fontsize=11)

    # ── MIXER — colour blends BufA→BufB by %B ────────────────────────────────
    mixer_color = @lift begin
        td = $(app.trend_data)
        f = isempty(td) ? 0.0 : clamp(td[end].pctb / 100.0, 0.0, 1.0)
        RGBf((1 - f) * COL_BUF_A.r + f * COL_BUF_B.r,
            (1 - f) * COL_BUF_A.g + f * COL_BUF_B.g,
            (1 - f) * COL_BUF_A.b + f * COL_BUF_B.b)
    end
    poly!(ax, Rect2f(x_c - 0.65, y_mix - 0.36, 1.30, 0.72);
        color=mixer_color, strokecolor=:black, strokewidth=1)
    mixer_label = @lift begin
        td = $(app.trend_data)
        isempty(td) ? "MIX" : @sprintf("%.0f%%B", td[end].pctb)
    end
    text!(ax, x_c, y_mix; text=mixer_label, fontsize=11,
        align=(:center, :center), font=:bold)

    inj_txt = text!(ax, x_c, y_inj; text="LOAD", fontsize=11,
        align=(:center, :center), font=:bold, color=:black)
    text!(ax, x_c, y_out; text="OUT", fontsize=11,
        align=(:center, :center), font=:bold, color=:black)
    out_txt = text!(ax, x_c, y_out - 0.95; text="TO WASTE", fontsize=11,
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

        inj_poly.color[] = is_unk ? :red :
                           is_wst ? :gray60 :
                           is_load ? :lightskyblue1 :
                           is_inj ? :orange : :lightgray
        out_poly.color[] = out_to_frac ? :lightgreen : :gray70

        inj_txt.text[] = _inject_label(s.inject_value)
        out_txt.text[] = is_unk ? "PATH UNKNOWN" :
                         (out_to_frac ? "TO FRAC #$(s.fraction_number)" : "TO WASTE")
    end
end
