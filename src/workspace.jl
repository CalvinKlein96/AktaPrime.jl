# workspace.jl — the application window: a top bar with tabs (live data, opened
# runs, settings) and menu buttons, above the page of the active tab. Every page
# is its own Figure; switching tabs displays that Figure in the same window.

const COL_TAB = RGBf(0.93, 0.93, 0.93)
const COL_TAB_ACTIVE = RGBf(0.78, 0.86, 0.97)

mutable struct Page
    title::String
    fig::Figure
    closable::Bool
    listeners::Vector{Any}   # its top bar's subscriptions, released when it closes
end

mutable struct Workspace
    acq::Acquisition
    screen::Any                  # the GLMakie window, once displayed
    pages::Vector{Page}
    active::Union{Nothing,Page}
    tabs_changed::Observable{Int}
end
Workspace(acq::Acquisition) = Workspace(acq, nothing, Page[], nothing, Observable(0))

# Runs `f` after the current GUI callback returns: a tab button must not delete
# itself, or replace the figure it belongs to, from inside its own click handler.
_later(f) = @async (yield(); f())

# Builds the top bar into `pos`; every page has its own copy, kept in sync.
function _topbar(ws::Workspace, listeners::Vector{Any})
    return function (pos)
        bar = GridLayout(pos; tellwidth=false)
        tabs = GridLayout(bar[1, 1]; halign=:left, default_colgap=2)
        Label(bar[1, 2], ws.acq.status; halign=:right, fontsize=13, color=:gray25,
            tellwidth=false)
        open_btn = Button(bar[1, 3]; label="Open run…", fontsize=13)
        set_btn = Button(bar[1, 4]; label="Settings", fontsize=13)
        colgap!(bar, 10)

        tab_btns = Any[]
        function rebuild()
            foreach(delete!, tab_btns)
            empty!(tab_btns)
            trim!(tabs)
            col = 0
            for p in ws.pages
                active = p === ws.active
                b = Button(tabs[1, col+=1]; label=p.title, fontsize=13,
                    font=active ? :bold : :regular,
                    buttoncolor=active ? COL_TAB_ACTIVE : COL_TAB)
                on(_ -> _later(() -> show_page!(ws, p)), b.clicks)
                push!(tab_btns, b)
                if p.closable
                    x = Button(tabs[1, col+=1]; label="×", fontsize=13,
                        buttoncolor=active ? COL_TAB_ACTIVE : COL_TAB)
                    on(_ -> _later(() -> close_page!(ws, p)), x.clicks)
                    push!(tab_btns, x)
                end
            end
        end
        push!(listeners, on(_ -> rebuild(), ws.tabs_changed))
        rebuild()

        on(_ -> _later(() -> open_run!(ws)), open_btn.clicks)
        on(_ -> _later(() -> open_settings!(ws)), set_btn.clicks)
    end
end

function add_page!(build, ws::Workspace, title::String; closable::Bool=true)::Page
    listeners = Any[]
    page = Page(title, build(_topbar(ws, listeners)), closable, listeners)
    push!(ws.pages, page)
    return page
end

function show_page!(ws::Workspace, page::Page)
    ws.active = page
    ws.tabs_changed[] += 1
    isnothing(ws.screen) || display(ws.screen, page.fig)
end

function close_page!(ws::Workspace, page::Page)
    page.closable || return
    filter!(p -> p !== page, ws.pages)
    foreach(off, page.listeners)
    ws.active === page ? show_page!(ws, first(ws.pages)) : (ws.tabs_changed[] += 1)
end

# ── Open run… ────────────────────────────────────────────────────────────────
function open_run!(ws::Workspace)
    path = try
        NativeFileDialog.pick_file(pwd(); filterlist="csv")
    catch err
        @error "Could not open the file dialog" exception = err
        ""
    end
    isempty(path) && return
    title = basename(path)
    existing = findfirst(p -> p.title == title, ws.pages)
    isnothing(existing) || return show_page!(ws, ws.pages[existing])

    app = AppState()
    try
        load_csv_log!(app, path)
    catch err
        @error "Could not read $path" exception = err
        return
    end
    app.log_filename = path
    @info "Opened $path"
    show_page!(ws, add_page!(topbar -> build_gui(app; viewer=true, topbar), ws, title))
end

# ── Settings ─────────────────────────────────────────────────────────────────
const VOLUME_UNIT_OPTIONS = ["1 µL per count (ÄKTAprime)", "10 µL per count (ÄKTAprime plus)"]

function open_settings!(ws::Workspace)
    existing = findfirst(p -> p.title == "Settings", ws.pages)
    isnothing(existing) || return show_page!(ws, ws.pages[existing])
    show_page!(ws, add_page!(topbar -> _settings_figure(ws, topbar), ws, "Settings"))
end

function _settings_figure(ws::Workspace, topbar)::Figure
    acq, s = ws.acq, ws.acq.settings
    fig = Figure(size=(1440, 900), backgroundcolor=:white)
    topbar(fig[1, 1])
    g = GridLayout(fig[2, 1]; halign=:left, valign=:top, tellwidth=false, tellheight=false,
        alignmode=Outside(40))
    lbl(row, txt) = Label(g[row, 1], txt; halign=:right, fontsize=15)
    note(row, txt) = Label(g[row, 3], txt; halign=:left, fontsize=12, color=:gray40)

    Label(g[1, 1:3], "Settings"; halign=:left, fontsize=20, font=:bold)

    lbl(2, "Demo mode")
    demo = Toggle(g[2, 2]; active=s.demo_mode, halign=:left)
    note(2, "Simulated data for testing; no instrument needed.")

    lbl(3, "Serial port")
    port = Textbox(g[3, 2]; stored_string=s.serial_port, width=260, fontsize=14,
        halign=:left)
    note(3, "Press Enter to apply, e.g. /dev/ttyUSB0 (Linux) or COM3 (Windows).")

    lbl(4, "Volume unit")
    unit = Menu(g[4, 2]; options=VOLUME_UNIT_OPTIONS, width=260, fontsize=14, halign=:left,
        default=s.volume_unit_uL == 1.0 ? VOLUME_UNIT_OPTIONS[1] : VOLUME_UNIT_OPTIONS[2])
    note(4, "Applies to data received from now on.")

    lbl(5, "Log file prefix")
    prefix = Textbox(g[5, 2]; stored_string=s.log_prefix, width=260, fontsize=14,
        halign=:left)
    note(5, "Press Enter to apply. Used for the next log file: <prefix>_<date>_<time>.csv")

    lbl(6, "Data folder")
    Label(g[6, 2:3], pwd(); halign=:left, fontsize=14)

    feedback = Label(g[7, 1:3], ""; halign=:left, fontsize=13, color=:darkgreen)
    rowgap!(g, 14)
    colgap!(g, 16)

    # Every change is saved at once; source changes restart the acquisition.
    function changed!(msg; restart=false)
        save_settings(s)
        restart && restart!(acq)
        feedback.text = msg
    end
    on(demo.active) do on_
        s.demo_mode == on_ && return
        s.demo_mode = on_
        _later(() -> changed!(on_ ? "Demo mode on — showing simulated data." :
                                    "Demo mode off — connecting to $(s.serial_port)."; restart=true))
    end
    on(port.stored_string) do str
        str = strip(something(str, ""))
        (isempty(str) || str == s.serial_port) && return
        s.serial_port = str
        _later(() -> changed!("Serial port set to $str." * (s.demo_mode ? "" : " Reconnecting.");
            restart=!s.demo_mode))
    end
    on(unit.selection) do sel
        unit_uL = sel == VOLUME_UNIT_OPTIONS[1] ? 1.0 : 10.0
        s.volume_unit_uL == unit_uL && return
        s.volume_unit_uL = VOLUME_UNIT_UL[] = unit_uL
        changed!("Volume unit set to $(Int(unit_uL)) µL per count.")
    end
    on(prefix.stored_string) do str
        str = strip(something(str, ""))
        (isempty(str) || str == s.log_prefix) && return
        s.log_prefix = acq.app.log_prefix = str
        changed!("Log prefix set to \"$str\"; the next log file will use it.")
    end
    return fig
end
