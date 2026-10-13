# settings.jl — user settings, saved with Preferences.jl (LocalPreferences.toml)
# and edited on the Settings page of the GUI.

const SERIAL_PORT_PREFERENCE_KEY = "serial_port"
const VOLUME_UNIT_PREFERENCE_KEY = "volume_unit_uL"   # 10 for ÄKTAprime plus, 1 for ÄKTAprime
const DEMO_MODE_PREFERENCE_KEY = "demo_mode"
const LOG_PREFIX_PREFERENCE_KEY = "log_prefix"
const DATA_DIR_PREFERENCE_KEY = "data_dir"

mutable struct Settings
    demo_mode::Bool          # simulated data instead of the instrument
    serial_port::String
    volume_unit_uL::Float64  # µL per volume count
    log_prefix::String       # CSV files are named <prefix>_<date>_<time>.csv
    data_dir::String         # folder for log files and plots; "" = current folder
end

load_settings() = Settings(
    @load_preference(DEMO_MODE_PREFERENCE_KEY, false),
    @load_preference(SERIAL_PORT_PREFERENCE_KEY, DEFAULT_SERIAL_PORT),
    Float64(@load_preference(VOLUME_UNIT_PREFERENCE_KEY, DEFAULT_VOLUME_UNIT_UL)),
    @load_preference(LOG_PREFIX_PREFERENCE_KEY, "akta"),
    @load_preference(DATA_DIR_PREFERENCE_KEY, ""),
)

# The data folder in use: the saved one if it exists or can be created, else
# the current folder.
function data_dir(s::Settings)::String
    isempty(s.data_dir) && return pwd()
    try
        mkpath(s.data_dir)
        return s.data_dir
    catch err
        @warn "Data folder $(s.data_dir) is not usable — saving to $(pwd()) instead" exception = err
        return pwd()
    end
end

function save_settings(s::Settings)
    @set_preferences!(
        DEMO_MODE_PREFERENCE_KEY => s.demo_mode,
        SERIAL_PORT_PREFERENCE_KEY => s.serial_port,
        VOLUME_UNIT_PREFERENCE_KEY => s.volume_unit_uL,
        LOG_PREFIX_PREFERENCE_KEY => s.log_prefix,
        DATA_DIR_PREFERENCE_KEY => s.data_dir,
    )
end
