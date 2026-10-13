# gui.jl — GLMakie real-time chromatography display

# ── Colour palette ────────────────────────────────────────────────────────────
const COL_UV = RGBf(0.15, 0.35, 0.70)
const COL_COND = RGBf(0.80, 0.20, 0.10)
const COL_PCTB = RGBf(0.10, 0.55, 0.25)
const COL_PRES = RGBf(0.75, 0.45, 0.00)
const COL_PH = RGBf(0.55, 0.25, 0.65)
const COL_FLOW = RGBf(0.10, 0.45, 0.55)

const COL_BUF_A = RGBf(0.80, 0.10, 0.10)   # red — buffer valve port 1 (standard buffer A)
const COL_BUF_PORT = RGBf(0.95, 0.55, 0.25)   # orange — buffer valve ports 2–7
const COL_SAMPLE = RGBf(0.70, 0.35, 0.80)   # violet — buffer valve port 8 (sample loading)
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
            return uppercase(m.captures[1])
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
        t = strip(e.text)
        for (re, short) in ((r"^(?:Manual Set;\s*)?Buffer Valve Pos\s+(\d+)"i, "Buffer "),
            (r"^Injection Valve (\w+)"i, "Inj valve "), (r"^Flow ([0-9.]+) ml/min"i, "Flow "),
            (r"^(?:Manual Set;\s*)?Concentration ([0-9.]+) %B"i, "%B "),
            (r"^Feed Tube Nr\s+(\d+)"i, "Tube "))
            m = match(re, t)
            isnothing(m) || return short * m.captures[1]
        end
        startswith(t, "Method start") && return "Method start"
        return length(t) > 20 ? first(t, 18) * "…" : t
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

# Set flow, as reported by the instrument's "Flow 1.0 ml/min" log messages.
_flow_from_log(text::AbstractString)::Union{Nothing,Float64} =
    let m = match(r"^Flow\s+([0-9]+(?:\.[0-9]+)?)\s*ml/min$"i, strip(text))
        m === nothing ? nothing : parse(Float64, m.captures[1])
    end

# Step-plot points of the set flow: one per flow log event, with the last value
# held up to the newest data point.
function _flow_setpoints(events::AbstractVector{AktaEvent}, trend::AbstractVector{TrendPoint},
    by_vol::Bool)::Vector{Point2f}
    pts = Point2f[]
    for e in events
        e.kind == EVT_LOG || continue
        flow = _flow_from_log(e.text)
        isnothing(flow) || push!(pts, Point2f(_event_x(e, by_vol), flow))
    end
    if !isempty(pts) && !isempty(trend)
        xend = _trend_x(trend[end], by_vol)
        xend > pts[end][1] && push!(pts, Point2f(xend, pts[end][2]))
    end
    return pts
end

# Overlay mode: scale a trace to 0–100 % of its own range. %B already is a
# percentage; flow is scaled from 0 so it reads as a fraction of the top flow.
# Returns the scaled points and the (lo, hi) range that maps to 0–100 %.
function _normalise(pts::AbstractVector{<:Point2}, key::Symbol)
    key === :pctb && return Vector{Point2f}(pts), (0.0f0, 100.0f0)
    ys = [p[2] for p in pts]
    lo = key === :flow ? 0.0f0 : Float32(minimum(ys))
    hi = Float32(maximum(ys))
    span = hi - lo
    scaled = span > 0 ? [Point2f(p[1], (p[2] - lo) / span * 100) for p in pts] :
             [Point2f(p[1], 50) for p in pts]
    return scaled, (lo, hi)
end

# Overlay y-range: headroom above 100 % so traces are not squashed against the top.
const OVERLAY_YLIMS = (-3, 110)

_channel_ylabel(name, unit) = isempty(unit) ? name : "$name ($unit)"

# Overlay y-axis: in % of range by default, or in the real units of the highlighted
# trace. `getrange()` returns that trace's current (lo, hi), which map to 0–100 %;
# ticks are chosen on the real values and placed at their scaled positions.
function _set_overlay_yaxis!(ax, highlight)
    if isnothing(highlight)
        ax.yticks = Makie.automatic
        ax.ytickformat = Makie.automatic
        ax.ylabel = "Scaled (% of range)"
        ax.ylabelcolor = :black
        ax.yticklabelcolor = :black
        return
    end
    name, unit, col, getrange = highlight
    function toreal(v)
        lo, hi = getrange()
        return lo + v / 100 * (hi - lo)
    end
    ax.yticks = (vmin, vmax) -> begin
        lo, hi = getrange()
        span = hi - lo
        span > 0 || return [50.0]
        t = Makie.get_tickvalues(LinearTicks(6), toreal(vmin), toreal(vmax))
        return (t .- lo) ./ span .* 100
    end
    ax.ytickformat = vals -> Makie.get_ticklabels(Makie.automatic, toreal.(vals))
    ax.ylabel = _channel_ylabel(name, unit)
    ax.ylabelcolor = col
    ax.yticklabelcolor = col
    return
end

_overlay_label(name, unit, (lo, hi)) =
    "━━  $name   ($(@sprintf("%.3g", lo))–$(@sprintf("%.3g", hi))$(isempty(unit) ? "" : " $unit"))"

# Event labels start just right of their event line, in rows from the top of the
# visible area: a label moves down a row only if it would overlap one already
# placed. Laid out in screen pixels, so it is redone whenever the view changes.
const EVENT_LABEL_FONTSIZE = 8

function _event_label_positions(xs::AbstractVector{<:Real}, labels::AbstractVector{<:AbstractString},
    lims::Rect2, px::AbstractVector{<:Real}, avoid=nothing)::Vector{Point2f}
    x0, y0 = lims.origin
    w, h = lims.widths
    pxw, pxh = max(px[1], 1), max(px[2], 1)
    gap = 3                                            # px between line and label
    rowh = EVENT_LABEL_FONTSIZE * 1.3                  # px per row
    row_end = Float64[]                                # right edge (px) of each row
    pts = Vector{Point2f}(undef, length(xs))
    # `avoid` = (left, right, top, bottom) px box, top/bottom measured from the top edge
    blocked(r, start, stop) = !isnothing(avoid) && start < avoid[2] && stop > avoid[1] &&
                              2 + r * rowh > avoid[3] && 2 + (r - 1) * rowh < avoid[4]
    for i in sortperm(xs)
        start = (xs[i] - x0) / w * pxw + gap
        stop = start + length(labels[i]) * EVENT_LABEL_FONTSIZE * 0.6 + gap
        r = 1
        while (r <= length(row_end) && row_end[r] >= start) || blocked(r, start, stop)
            r += 1
        end
        while length(row_end) < r
            push!(row_end, -Inf)
        end
        row_end[r] = stop
        pts[i] = Point2f(xs[i] + gap / pxw * w, y0 + h - (2 + (r - 1) * rowh) / pxh * h)
    end
    return pts
end

function _event_labels!(ax, evts, x_mode_is_vol; avoid=Observable(nothing))
    lbls = @lift [_event_label_top(e) for e in $evts]
    pts = @lift _event_label_positions([_event_x(e, $x_mode_is_vol) for e in $evts], $lbls,
        $(ax.finallimits), $(ax.scene.viewport).widths, $avoid)
    text!(ax, pts; text=lbls, fontsize=EVENT_LABEL_FONTSIZE, color=:gray25,
        align=(:left, :top), xautolimits=false, yautolimits=false)
end

# ─────────────────────────────────────────────────────────────────────────────
# Inspecting a past moment
# ─────────────────────────────────────────────────────────────────────────────
const _INJECT_NAMES = Dict(string(v) => v for v in instances(InjectValue))

# Instrument state at a past moment, rebuilt by replaying the logged events up to
# `p` with the same decoders the live link uses. Every event is in the CSV, so
# this works for reopened logs too.
function _state_at(events::AbstractVector{AktaEvent}, p::TrendPoint)::InstrumentState
    s = InstrumentState()
    for e in events
        e.cum_time_ms <= p.cum_time_ms || continue
        if e.kind == EVT_RUN_STATE
            m = match(r"Run state:\s*(\S+)\s+inject=(\w+)", e.text)
            if !isnothing(m)
                s.run_state = m.captures[1]
                s.inject_value = get(_INJECT_NAMES, m.captures[2], s.inject_value)
            end
        elseif e.kind == EVT_LOG
            if (m = match(r"^Method start:.*buffer port (\d+), inject (\w+)", e.text)) !== nothing
                s.buffer_port = parse(Int, m.captures[1])
                s.buffer_port_known = true
                inj = lowercase(m.captures[2])
                s.inject_value = inj == "load" ? IV_LOAD : inj == "inj" ? IV_INJECT :
                                 inj == "waste" ? IV_WASTE : s.inject_value
            elseif (m = match(r"^Fraction size\s+([0-9.]+)\s+ml$"i, strip(e.text))) !== nothing
                s.fraction_vol_mL = parse(Float64, m.captures[1])
            elseif (m = match(r"^Feed Tube Nr\s+(\d+)$"i, strip(e.text))) !== nothing
                s.fraction_number = max(1, parse(Int, m.captures[1]))
            else
                _set_inject_from_log!(e.text, s) || _set_buffer_valve_from_log!(e.text, s)
            end
        end
    end
    s.cum_time_ms = s.run_time_ms = p.cum_time_ms
    s.cum_vol_mL = s.run_vol_mL = p.cum_vol_mL
    return s
end

# Set flow (mL/min) in force at `p`, or nothing before the first flow message.
function _flow_at(events::AbstractVector{AktaEvent}, p::TrendPoint)
    flow = nothing
    for e in events
        e.kind == EVT_LOG && e.cum_time_ms <= p.cum_time_ms || continue
        f = _flow_from_log(e.text)
        isnothing(f) || (flow = f)
    end
    return flow
end

function _status_text(s::InstrumentState, p::Union{Nothing,TrendPoint}, flow, header::String,
    file::String)::String
    port = s.buffer_port == 1 ? "1 (A)" : s.buffer_port == 8 ? "8 (sample)" : string(s.buffer_port)
    port *= s.buffer_port_known ? "" : " — assumed"
    values = isnothing(p) ? "" : """

UV: $(@sprintf("%.4f", p.uv)) AU   %B: $(@sprintf("%.1f", p.pctb))
Cond: $(@sprintf("%.2f", p.cond_mScm)) mS/cm   pH: $(@sprintf("%.2f", p.ph))
Pressure: $(@sprintf("%.3f", p.pres_MPa)) MPa   T: $(@sprintf("%.1f", p.temp_degC)) °C"""
    return """
$header
State: $(s.run_state)
Run time: $(@sprintf("%.2f", s.run_time_ms / 60_000)) min
Run volume: $(@sprintf("%.4f", s.run_vol_mL)) mL
Flow: $(isnothing(flow) ? "---" : @sprintf("%.2f mL/min", flow))
Valve: $(lowercase(_inject_label(s.inject_value)))
Buffer valve: $port
Output: $(s.fraction_vol_mL > 0 ? "frac collector" : "waste")
Fraction #: $(s.fraction_number)
Fraction volume: $(@sprintf("%.2f", s.fraction_vol_mL)) mL$values
File: $file"""
end

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
function build_gui(app::AppState; viewer::Bool=false, topbar=nothing,
    status::Union{Nothing,Observable{String}}=nothing)::Figure
    fig = Figure(size=(1440, 900), backgroundcolor=:white)

    # Layout, one area per job:
    #   top bar      navigation and global actions (tabs, menu; see workspace.jl)
    #   toolbar      how the data is viewed            │ right panel: what the
    #   plots, slider                                   │ instrument is doing
    #   status bar   connection, recording, mouse help
    r = isnothing(topbar) ? 0 : 1          # rows below the (optional) top bar
    isnothing(topbar) || topbar(fig[1, 1])
    body = fig[r+1, 1] = GridLayout()
    toolbar = body[1, 1] = GridLayout(; halign=:left, tellwidth=false)
    left = body[2, 1] = GridLayout()
    right = body[1:2, 2] = GridLayout(; valign=:top)
    colsize!(body, 1, Relative(0.75))
    colsize!(body, 2, Relative(0.25))

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
    ax_rate = Axis(left[6, 1]; ylabel="Flow (mL/min)",
        ygridvisible=false, xgridvisible=false)
    # Overlay mode: all traces on one axis, each scaled to 0–100 % of its range.
    ax_ov = Axis(left[7, 1]; ylabel="Scaled (% of range)", ygridvisible=false,
        xgridvisible=false, limits=(nothing, OVERLAY_YLIMS))
    plot_axes = (ax_uv, ax_pctb, ax_cond, ax_ph, ax_pres, ax_rate, ax_ov)

    linkxaxes!(plot_axes...)

    # x label tracks the plotting mode; per-panel visibility is set by
    # refresh_panels! below so only the lowest visible panel carries it.
    for ax in plot_axes
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
    # Same empty-guard as _trend: a dummy point until the first flow message arrives.
    rate_pts = @lift let pts = _flow_setpoints($(app.events), $(app.trend_data), $x_mode_is_vol)
        isempty(pts) ? [Point2f(0, 0)] : pts
    end

    lines!(ax_uv, uv_pts, color=COL_UV, linewidth=1.5)
    pl_pctb = lines!(ax_pctb, pctb_pts, color=COL_PCTB, linewidth=1.5)
    pl_cond = lines!(ax_cond, cond_pts, color=COL_COND, linewidth=1.5)
    pl_ph = lines!(ax_ph, ph_pts, color=COL_PH, linewidth=1.5)
    pl_pres = lines!(ax_pres, pres_pts, color=COL_PRES, linewidth=1.5)
    pl_rate = stairs!(ax_rate, rate_pts; step=:post, color=COL_FLOW, linewidth=1.5)

    # ── Event vlines on UV panel ──────────────────────────────────────────────
    # xautolimits/yautolimits=false prevents Makie calling extrema on empty vectors.
    for kind in instances(EventKind)
        let kind = kind
            color, style = get(EVT_COLORS, kind, (:black, :dash))
            evts_k = @lift filter(e -> e.kind == kind, $(app.events))
            evt_x_k = @lift [_event_x(e, $x_mode_is_vol) for e in $evts_k]
            for ax in (ax_uv, ax_ov)
                vlines!(ax, evt_x_k; color=(color, 0.55), linestyle=style, linewidth=1.0,
                    xautolimits=false, yautolimits=false)
            end
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
    vspan!(ax_ov, frac_xstart, frac_xend;
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

    _event_labels!(ax_uv, evt_other, x_mode_is_vol)

    # ── Event legend ──────────────────────────────────────────────────────────
    # legend_elements = [LineElement(color=EVT_COLORS[k][1], linestyle=EVT_COLORS[k][2])
    #                    for k in (EVT_INJECT, EVT_RUN_STATE, EVT_STEP, EVT_LOG)]
    # legend_labels = ["Inject", "State", "Step", "Log"]
    # Legend(left[5, 1], legend_elements, legend_labels;
    #     orientation=:horizontal, framevisible=false, tellwidth=false,
    #     labelsize=11, patchsize=(18, 2))

    # ── Plot toolbar: x axis, stacked/overlay, visible panels, follow, export ──
    xmenu = Menu(toolbar[1, 1]; options=["Plot vs time", "Plot vs volume"],
        default="Plot vs time", width=150, fontsize=13)
    overlay = Observable(false)
    ov_btn = Button(toolbar[1, 2]; label="Overlay", fontsize=13)
    function check!(col, label)
        g = GridLayout(toolbar[1, col]; default_colgap=4)
        cb = Checkbox(g[1, 1]; checked=true)
        Label(g[1, 2], label; fontsize=13)
        return cb
    end
    # UV is always shown; these switch the other panels.
    tg_pctb = check!(3, "%B")
    tg_cond = check!(4, "Cond")
    tg_ph = check!(5, "pH")
    tg_pres = check!(6, "Pressure")
    tg_rate = check!(7, "Flow")
    # Follow live: auto-rescale to all data on each update. Switched off as soon
    # as the user zooms or pans, so a zoomed view stays put while the run continues.
    tg_follow = check!(8, "Follow live")
    save_btn = Button(toolbar[1, 9]; label="Save plot…", fontsize=13)
    colgap!(toolbar, 14)

    # ── Shown moment: live, or a past moment picked with the time slider ──────
    # The status text and schematic show `shown_state` / `shown_point`: the live
    # instrument state, or the state rebuilt from the log at the selected moment.
    # In viewer mode there is no live state, so the end of the log is the default.
    following = Observable(true)                 # slider at the end
    shown_state = Observable(app.inst[])
    shown_point = Observable{Union{Nothing,TrendPoint}}(nothing)
    shown_header = Observable("")

    # ── Status read-out — left-aligned text ────────────────────────────────────
    status_text = @lift _status_text($shown_state, $shown_point,
        isnothing($shown_point) ? nothing : _flow_at(app.events[], $shown_point),
        $shown_header, basename(app.log_filename))
    Label(right[1, 1], status_text;
        halign=:left, justification=:left, tellwidth=false, fontsize=13)

    # ── Flow path schematic ─────────────────────────────────────────────────────
    ax_flow = Axis(right[2, 1];
        xgridvisible=false, ygridvisible=false,
        xticksvisible=false, yticksvisible=false,
        xticklabelsvisible=false, yticklabelsvisible=false,
        leftspinevisible=false, rightspinevisible=false,
        topspinevisible=false, bottomspinevisible=false,
        limits=(0.3, 8.1, 1.3, 13.3))
    _draw_flow_schematic!(ax_flow, shown_state, shown_point)

    # Full-extent autoscale of every panel. All linked axes must be reset: one left
    # zoomed keeps the shared x-range stuck. %B keeps its fixed range, flow starts at 0.
    function rescale!()
        for ax in plot_axes
            ax.limits[] = ax === ax_pctb ? (nothing, (-3, 103)) :
                          ax === ax_ov ? (nothing, OVERLAY_YLIMS) :
                          ax === ax_rate ? (nothing, (0, nothing)) : (nothing, nothing)
            reset_limits!(ax)
        end
    end

    # On switching time<->volume, relabel the x-axis and reset the limits to fit
    # the data in the new units (equivalent to a zoom reset). Live updates and
    # manual zooming continue to work normally afterwards.
    on(xmenu.selection) do sel
        by_vol = sel == "Plot vs volume"
        x_mode_is_vol[] = by_vol
        lbl = by_vol ? "Volume (mL)" : "Time (min)"
        for ax in plot_axes
            ax.xlabel = lbl
        end
        tg_follow.checked[] = true   # notifies, so this also rescales
    end

    # Save the currently displayed plot (visible panels, current limits) to PDF.
    fig_counter = Ref(0)
    on(save_btn.clicks) do _
        _save_plot_pdf(app, plot_axes,
            (tg_pctb, tg_cond, tg_ph, tg_pres, tg_rate), x_mode_is_vol[], fig_counter;
            overlay=overlay[], highlighted=highlighted[])
    end

    # ── Overlay traces ──────────────────────────────────────────────────────────
    # (key, name, unit, colour, points, visibility toggle — nothing means always shown)
    ov_channels = (
        (:uv, "UV", "AU", COL_UV, uv_pts, nothing),
        (:pctb, "%B", "%", COL_PCTB, pctb_pts, tg_pctb),
        (:cond, "Cond", "mS/cm", COL_COND, cond_pts, tg_cond),
        (:ph, "pH", "", COL_PH, ph_pts, tg_ph),
        (:pres, "Pressure", "MPa", COL_PRES, pres_pts, tg_pres),
        (:flow, "Flow", "mL/min", COL_FLOW, rate_pts, tg_rate))

    # Clicking a legend entry highlights that trace; clicking it again clears it.
    highlighted = Observable{Union{Nothing,Symbol}}(nothing)
    ov_plots = Dict{Symbol,Any}()
    ov_labels = Dict{Symbol,Observable{String}}()
    ov_ranges = Dict{Symbol,Observable}()
    for (key, name, unit, col, pts, _) in ov_channels
        norm = @lift _normalise($pts, key)
        ov_ranges[key] = @lift $norm[2]
        ov_labels[key] = @lift _overlay_label(name, unit, $norm[2])
        color = @lift isnothing($highlighted) || $highlighted === key ?
                      RGBAf(col.r, col.g, col.b, 1.0) : RGBAf(col.r, col.g, col.b, 0.2)
        lw = @lift $highlighted === key ? 3.0 : 1.5
        npts = @lift $norm[1]
        ov_plots[key] = key === :flow ?
                        stairs!(ax_ov, npts; step=:post, color=color, linewidth=lw) :
                        lines!(ax_ov, npts; color=color, linewidth=lw)
    end

    # The overlay y-axis shows the highlighted trace's real values.
    on(highlighted) do key
        i = findfirst(c -> c[1] === key, ov_channels)
        _set_overlay_yaxis!(ax_ov, isnothing(i) ? nothing :
            let (_, name, unit, col, _, _) = ov_channels[i]
                (name, unit, col, () -> ov_ranges[key][])
            end)
    end
    # Its range grows with the data, so refresh the ticks when it changes.
    on(app.trend_data) do _
        isnothing(highlighted[]) || notify(ax_ov.yticks)
    end

    # Legend: one button per visible trace, inside the top-left of the overlay axis.
    # Rebuilt whenever the visible traces change.
    legend = GridLayout(left[7, 1]; tellwidth=false, tellheight=false,
        halign=:left, valign=:top, alignmode=Outside(8), default_rowgap=3)
    legend_btns = Pair{Symbol,Button}[]

    # Overlay event labels go around the legend: its box in the axis' pixel space,
    # as (left, right, top, bottom) with top/bottom measured down from the top edge.
    legend_box = @lift let bb = $(legend.layoutobservables.computedbbox), vp = $(ax_ov.scene.viewport)
        bx = bb.origin[1] - vp.origin[1]
        by = vp.origin[2] + vp.widths[2] - (bb.origin[2] + bb.widths[2])
        (bx, bx + bb.widths[1], by, by + bb.widths[2])
    end
    _event_labels!(ax_ov, evt_other, x_mode_is_vol; avoid=legend_box)

    function style_legend!()
        for (key, btn) in legend_btns
            on_ = highlighted[] === key
            btn.font = on_ ? :bold : :regular
            btn.buttoncolor = on_ ? RGBf(0.90, 0.93, 0.98) : RGBAf(1, 1, 1, 0.85)
        end
    end

    function rebuild_legend!()
        foreach(kb -> delete!(kb[2]), legend_btns)
        empty!(legend_btns)
        trim!(legend)
        overlay[] || return
        for (key, _, _, col, _, tg) in ov_channels
            (isnothing(tg) || tg.checked[]) || continue
            btn = Button(legend[length(legend_btns)+1, 1]; label=ov_labels[key],
                fontsize=12, labelcolor=col, labelcolor_hover=col, labelcolor_active=col,
                buttoncolor_hover=RGBf(0.95, 0.95, 0.95), buttoncolor_active=RGBf(0.85, 0.88, 0.95),
                strokecolor=(col, 0.6), strokewidth=1, cornerradius=4,
                padding=(6, 6, 3, 3), halign=:left)
            on(btn.clicks) do _
                highlighted[] = highlighted[] === key ? nothing : key
                style_legend!()
            end
            push!(legend_btns, key => btn)
        end
        # A highlighted trace that was just hidden cannot stay highlighted.
        any(kb -> kb[1] === highlighted[], legend_btns) || (highlighted[] = nothing)
        style_legend!()
    end

    # ── Panel show/hide ─────────────────────────────────────────────────────────
    # Hiding a panel collapses its row *and* turns off its plots and every
    # decoration, so no orphaned frame, ticks or labels are left behind.  UV is
    # always shown; the toggles drive the other five.  The lowest visible panel
    # carries the shared x tick labels and axis label.  In overlay mode all the
    # stacked panels collapse and only the overlay axis (row 7) is shown.
    panels = ((ax_pctb, 2, tg_pctb), (ax_cond, 3, tg_cond),
        (ax_ph, 4, tg_ph), (ax_pres, 5, tg_pres), (ax_rate, 6, tg_rate))

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

    function setpanel!(ax, row, vis)
        foreach(p -> p.visible[] = vis, ax.scene.plots)
        showaxis!(ax, vis)
        rowsize!(left, row, vis ? Auto() : Fixed(0))
    end

    gap0 = left.addedrowgaps[1]   # the layout's normal gap between panels

    function refresh_panels!()
        ov = overlay[]
        visible = Axis[]
        setpanel!(ax_uv, 1, !ov)
        ov || push!(visible, ax_uv)
        for (ax, row, tg) in panels
            vis = !ov && tg.checked[]
            setpanel!(ax, row, vis)
            vis && push!(visible, ax)
        end
        setpanel!(ax_ov, 7, ov)
        if ov
            for (key, _, _, _, _, tg) in ov_channels
                ov_plots[key].visible[] = isnothing(tg) || tg.checked[]
            end
            push!(visible, ax_ov)
        end
        bottom = visible[end]
        bottom.xticklabelsvisible = true
        bottom.xlabelvisible = true
        # Collapsed rows keep their gaps, so only keep a gap between two shown panels.
        shown = [!ov; [!ov && tg.checked[] for (_, _, tg) in panels]; ov]
        for i in 1:6
            rowgap!(left, i, shown[i] && any(shown[i+1:end]) ? gap0 : Fixed(0))
        end
        rebuild_legend!()
    end

    for (_, _, tg) in panels
        on(_ -> refresh_panels!(), tg.checked)
    end
    on(ov_btn.clicks) do _
        overlay[] = !overlay[]
        ov_btn.label = overlay[] ? "Stacked" : "Overlay"
        refresh_panels!()
        tg_follow.checked[] && rescale!()
    end
    refresh_panels!()

    # A user zoom/pan freezes the view; Ctrl-click (Makie's limit reset) resumes following.
    for ax in plot_axes
        register_interaction!(ax, :follow_live) do event, _
            if event isa ScrollEvent ||
               (event isa MouseEvent &&
                event.type in (MouseEventTypes.leftdragstop, MouseEventTypes.rightdragstop))
                tg_follow.checked[] = false
            elseif event isa MouseEvent && event.type == MouseEventTypes.leftclick &&
                   ispressed(fig, Keyboard.left_control | Keyboard.right_control)
                tg_follow.checked[] = true
            end
            return Consume(false)
        end
    end

    on(tg_follow.checked) do follow
        follow && rescale!()
    end

    on(app.trend_data) do _
        tg_follow.checked[] && rescale!()
    end

    # ── Status bar: connection · recording · mouse help ────────────────────────
    Box(fig[r+2, 1]; color=RGBf(0.95, 0.95, 0.95), strokevisible=false)
    statusbar = GridLayout(fig[r+2, 1]; alignmode=Outside(6), tellwidth=false)
    conn = isnothing(status) ? Observable(viewer ? "" : "Live") : status
    Label(statusbar[1, 1], conn; halign=:left, fontsize=12, color=:gray25)
    recording = @lift begin
        td = $(app.trend_data)
        $(app.events)
        file = basename(app.log_filename)
        if viewer
            "Viewing $file · $(length(td)) points"
        elseif isnothing(app.csv_io)
            "Not recording"
        else
            t = isempty(td) ? 0.0 : td[end].cum_time_ms / 60_000
            "● REC  $file · $(@sprintf("%.1f", t)) min"
        end
    end
    Label(statusbar[1, 2], recording; halign=:left, fontsize=12,
        color=@lift(startswith($recording, "●") ? :firebrick : :gray25))
    Label(statusbar[1, 3], "Drag: zoom · Right-drag: pan · Ctrl-click: reset · Alt/Shift-click: inspect moment";
        halign=:right, fontsize=11, color=:gray45, tellwidth=false)
    colgap!(statusbar, 24)

    # ── Time slider: inspect a past moment ─────────────────────────────────────
    # Selects a trend point; at the right end it follows the newest data. The
    # moment is marked in every panel, and status + schematic show its state.
    slider_row = left[8, 1] = GridLayout(; tellwidth=false)
    sel_slider = Slider(slider_row[1, 1]; range=1:1, startvalue=1)
    sel_label = Label(slider_row[1, 2], ""; width=170, halign=:left, fontsize=13)
    end_btn = Button(slider_row[1, 3]; label=viewer ? "End" : "Live", fontsize=13)
    colgap!(slider_row, 10)

    function update_shown!()
        td = app.trend_data[]
        i = clamp(sel_slider.value[], 1, max(1, length(td)))
        p = isempty(td) ? nothing : td[i]
        if following[] && !viewer
            shown_state[] = app.inst[]
            shown_header[] = "● Live"
            sel_label.text = "Live"
        elseif isnothing(p)
            shown_header[] = ""
            sel_label.text = ""
        else
            shown_state[] = _state_at(app.events[], p)
            where = @sprintf("%.2f min · %.3f mL", p.cum_time_ms / 60_000, p.cum_vol_mL)
            shown_header[] = (following[] ? "End of log: " : "◀ Viewing: ") * where
            sel_label.text = where
        end
        shown_point[] = p
    end

    on(sel_slider.value) do i
        following[] = i >= length(app.trend_data[])
        update_shown!()
    end
    on(end_btn.clicks) do _
        set_close_to!(sel_slider, length(app.trend_data[]))
        following[] = true
        update_shown!()
    end
    # New data: extend the slider; keep the newest point selected while following.
    on(app.trend_data) do td
        sel_slider.range[] = 1:max(1, length(td))
        following[] ? set_close_to!(sel_slider, length(td)) : update_shown!()
    end
    live_view() = following[] && !viewer
    on(_ -> live_view() && update_shown!(), app.inst)            # live state changed
    on(_ -> live_view() || update_shown!(), app.events)          # a past state may change

    # Dashed marker at the selected moment in every panel (none while following live).
    marker_x = @lift begin
        td = $(app.trend_data)
        $following || isempty(td) ? Float32[] :
            [_trend_x(td[clamp($(sel_slider.value), 1, length(td))], $x_mode_is_vol)]
    end
    for ax in plot_axes
        vlines!(ax, marker_x; color=(:black, 0.7), linestyle=:dash, linewidth=1.5,
            xautolimits=false, yautolimits=false)
        # Alt- or Shift-click jumps the slider to the nearest data point.
        register_interaction!(ax, :inspect_moment) do event, _
            event isa MouseEvent && event.type == MouseEventTypes.leftclick || return Consume(false)
            ispressed(fig, Keyboard.left_alt | Keyboard.right_alt | Keyboard.left_shift |
                           Keyboard.right_shift) || return Consume(false)
            td = app.trend_data[]
            isempty(td) && return Consume(false)
            xs = _trend_x.(td, x_mode_is_vol[])
            set_close_to!(sel_slider, argmin(abs.(xs .- event.data[1])))
            return Consume(true)
        end
    end

    sel_slider.range[] = 1:max(1, length(app.trend_data[]))
    set_close_to!(sel_slider, length(app.trend_data[]))
    update_shown!()

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
function _save_plot_pdf(app::AppState, axes, toggles, by_vol::Bool, counter::Ref{Int};
    overlay::Bool=false, highlighted::Union{Nothing,Symbol}=nothing)
    trend = copy(app.trend_data[])
    if isempty(trend)
        @warn "Nothing to save yet — no data on the plot"
        return
    end
    events = copy(app.events[])
    fracs = copy(app.fractions[])
    ax_uv, ax_pctb, ax_cond, ax_ph, ax_pres, ax_rate, ax_ov = axes
    tg_pctb, tg_cond, tg_ph, tg_pres, tg_rate = toggles

    # Visible panels top-to-bottom (UV always); keep the source axis for its y-limits.
    specs = Tuple{Axis,Symbol,String,RGBf}[(ax_uv, :uv, "UV (AU)", COL_UV)]
    tg_pctb.checked[] && push!(specs, (ax_pctb, :pctb, "%B", COL_PCTB))
    tg_cond.checked[] && push!(specs, (ax_cond, :cond, "Conductivity (mS/cm)", COL_COND))
    tg_ph.checked[] && push!(specs, (ax_ph, :ph, "pH", COL_PH))
    tg_pres.checked[] && push!(specs, (ax_pres, :pres, "Pressure (MPa)", COL_PRES))
    tg_rate.checked[] && push!(specs, (ax_rate, :flow, "Flow (mL/min)", COL_FLOW))

    xr = ax_uv.finallimits[]
    xlo, xhi = xr.origin[1], xr.origin[1] + xr.widths[1]
    xlab = by_vol ? "Volume (mL)" : "Time (min)"

    # Both views on one page: the stacked panels, then the overlay below them.
    # The overlay keeps its on-screen y-range only when it is the view being shown.
    yr = ax_ov.finallimits[]
    ov_ylims = overlay ? (yr.origin[2], yr.origin[2] + yr.widths[2]) : OVERLAY_YLIMS
    expfig = Figure(size=(1000, 200 * length(specs) + 500), backgroundcolor=:white)
    _stacked_export!(expfig[1, 1], trend, events, fracs, specs, by_vol, xlab, (xlo, xhi))
    _overlay_export!(expfig[2, 1], trend, events, fracs, specs, by_vol, xlab, (xlo, xhi),
        ov_ylims, highlighted)
    rowsize!(expfig.layout, 2, Relative(500 / (200 * length(specs) + 500)))

    counter[] += 1
    prefix = isempty(app.log_prefix) ? "akta" : app.log_prefix
    stamp = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
    path = joinpath(app.log_dir, "$(prefix)_$(stamp)_figure_$(counter[]).pdf")

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

# Data points of one channel for export, in the current x units.
_export_points(chan::Symbol, trend, events, by_vol::Bool)::Vector{Point2f} =
    chan === :flow ? _flow_setpoints(events, trend, by_vol) :
    [Point2f(_trend_x(p, by_vol), _channel_value(p, chan)) for p in trend]

# Stacked export: one panel per visible channel, each with its on-screen y-limits.
function _stacked_export!(pos, trend, events, fracs, specs, by_vol::Bool, xlab, (xlo, xhi))
    grid = GridLayout(pos)
    exaxes = Axis[]
    for (i, (srcax, chan, ylab, col)) in enumerate(specs)
        bottom = i == length(specs)
        ax = Axis(grid[i, 1]; ylabel=ylab, xlabel=(bottom ? xlab : ""),
            xgridvisible=false, ygridvisible=false, xticklabelsvisible=bottom)
        (chan === :uv || chan === :pctb) &&
            _draw_fraction_spans!(ax, fracs, trend, by_vol; labels=(chan === :pctb))
        if chan === :uv
            for e in events
                c, style = get(EVT_COLORS, e.kind, (:black, :dash))
                vlines!(ax, [_event_x(e, by_vol)]; color=(c, 0.55), linestyle=style, linewidth=1.0)
            end
        end
        pts = _export_points(chan, trend, events, by_vol)
        if chan === :flow
            isempty(pts) || stairs!(ax, pts; step=:post, color=col, linewidth=1.5)
        else
            lines!(ax, pts; color=col, linewidth=1.5)
        end
        yr = srcax.finallimits[]
        ylims!(ax, yr.origin[2], yr.origin[2] + yr.widths[2])
        push!(exaxes, ax)
    end
    linkxaxes!(exaxes...)
    xlims!(exaxes[1], xlo, xhi)
    return
end

# Overlay export: every visible channel on one axis scaled to 0–100 %, with the
# on-screen highlight (y-axis in its units) and a legend giving each trace's range.
function _overlay_export!(pos, trend, events, fracs, specs, by_vol::Bool, xlab,
    (xlo, xhi), (ylo, yhi), highlighted)
    ax = Axis(pos; xlabel=xlab, xgridvisible=false, ygridvisible=false)
    _set_overlay_yaxis!(ax, nothing)
    _draw_fraction_spans!(ax, fracs, trend, by_vol)
    for e in events
        c, style = get(EVT_COLORS, e.kind, (:black, :dash))
        vlines!(ax, [_event_x(e, by_vol)]; color=(c, 0.55), linestyle=style, linewidth=1.0)
    end
    names = Dict(:uv => ("UV", "AU"), :pctb => ("%B", "%"), :cond => ("Cond", "mS/cm"),
        :ph => ("pH", ""), :pres => ("Pressure", "MPa"), :flow => ("Flow", "mL/min"))
    for (_, chan, _, col) in specs
        pts = _export_points(chan, trend, events, by_vol)
        isempty(pts) && continue
        scaled, range = _normalise(pts, chan)
        dim = !isnothing(highlighted) && highlighted !== chan
        color = RGBAf(col.r, col.g, col.b, dim ? 0.2 : 1.0)
        lw = highlighted === chan ? 3.0 : 1.5
        label = replace(_overlay_label(names[chan]..., range), "━━  " => "")
        highlighted === chan && _set_overlay_yaxis!(ax, (names[chan]..., col, () -> range))
        chan === :flow ?
            stairs!(ax, scaled; step=:post, color=color, linewidth=lw, label=label) :
            lines!(ax, scaled; color=color, linewidth=lw, label=label)
    end
    axislegend(ax; position=:lt, framevisible=true, labelsize=11)
    limits!(ax, xlo, xhi, ylo, yhi)
    return
end

# ─────────────────────────────────────────────────────────────────────────────
function _draw_flow_schematic!(ax, state::Observable{InstrumentState},
    point::Observable{Union{Nothing,TrendPoint}})
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

    # ── Buffer valve: 8 inlet ports in a row above it, feeding the A side ───
    # The active port is filled and piped to the valve; the valve feeds the mixer
    # (switch valve), where buffer B is mixed in.
    n_ports = 8
    x_vlv = 2.9
    y_port = 12.45
    port_x = [x_vlv + 0.62 * (i - (n_ports + 1) / 2) for i in 1:n_ports]
    port_color(i) = i == 1 ? COL_BUF_A : i == n_ports ? COL_SAMPLE : COL_BUF_PORT

    ln_ports = [lines!(ax, [port_x[i], x_vlv], [y_port - 0.24, y_buf + 0.31];
        color=port_color(i), linewidth=2.2, visible=false) for i in 1:n_ports]

    # Geometry chosen to mirror the requested routing diagrams.
    ln_buf_a = lines!(ax, [x_vlv, x_c], [y_buf - 0.31, y_mix + 0.02]; color=COL_BUF_A, linewidth=2.2, visible=false)
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
    port_polys = [poly!(ax, Rect2f(port_x[i] - 0.25, y_port - 0.24, 0.50, 0.48);
        color=:gray92, strokecolor=:black, strokewidth=1) for i in 1:n_ports]
    for i in 1:n_ports
        text!(ax, port_x[i], y_port; text=string(i), fontsize=10,
            align=(:center, :center), font=:bold)
    end
    text!(ax, port_x[1], y_port + 0.30; text="A", fontsize=9, align=(:center, :bottom), color=:gray35)
    text!(ax, port_x[end], y_port + 0.30; text="Sample", fontsize=9, align=(:center, :bottom), color=:gray35)
    vlv_poly = poly!(ax, Rect2f(x_vlv - 1.2, y_buf - 0.31, 2.4, 0.62);
        color=COL_BUF_A, strokecolor=:black, strokewidth=1)
    vlv_txt = text!(ax, x_vlv, y_buf; text="BUFFER VALVE", fontsize=10,
        align=(:center, :center), font=:bold)
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
        p = $point
        a = port_color($state.buffer_port)
        f = isnothing(p) ? 0.0 : clamp(p.pctb / 100.0, 0.0, 1.0)
        RGBf((1 - f) * a.r + f * COL_BUF_B.r,
            (1 - f) * a.g + f * COL_BUF_B.g,
            (1 - f) * a.b + f * COL_BUF_B.b)
    end
    poly!(ax, Rect2f(x_c - 0.65, y_mix - 0.36, 1.30, 0.72);
        color=mixer_color, strokecolor=:black, strokewidth=1)
    mixer_label = @lift isnothing($point) ? "MIX" : @sprintf("%.0f%%B", $point.pctb)
    text!(ax, x_c, y_mix; text=mixer_label, fontsize=11,
        align=(:center, :center), font=:bold)

    inj_txt = text!(ax, x_c, y_inj; text="LOAD", fontsize=11,
        align=(:center, :center), font=:bold, color=:black)
    text!(ax, x_c, y_out; text="OUT", fontsize=11,
        align=(:center, :center), font=:bold, color=:black)
    out_txt = text!(ax, x_c, y_out - 0.95; text="TO WASTE", fontsize=11,
        align=(:center, :center), font=:bold, color=:gray35)

    on(state) do s
        is_load = s.inject_value == IV_LOAD
        is_inj = s.inject_value == IV_INJECT
        is_wst = s.inject_value == IV_WASTE
        is_unk = s.inject_value == IV_UNKNOWN

        has_known_path = !is_unk
        setvisible!(ln_buf_a, has_known_path)

        # Buffer valve: fill and pipe the active port; dimmed while only assumed.
        port = s.buffer_port
        pcol = port_color(port)
        alpha = s.buffer_port_known ? 1.0 : 0.45
        for i in 1:n_ports
            port_polys[i].color[] = i == port ? RGBAf(pcol.r, pcol.g, pcol.b, alpha) : RGBAf(0.92, 0.92, 0.92, 1)
            setvisible!(ln_ports[i], has_known_path && i == port)
            ln_ports[i].alpha[] = alpha
        end
        ln_buf_a.color[] = RGBAf(pcol.r, pcol.g, pcol.b, alpha)
        vlv_poly.color[] = RGBAf(pcol.r, pcol.g, pcol.b, alpha)
        vlv_txt.text[] = s.buffer_port_known ? "BUFFER VALVE $port" : "BUFFER VALVE $port?"
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
