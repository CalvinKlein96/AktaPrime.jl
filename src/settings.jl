# settings.jl — user settings, saved with Preferences.jl (LocalPreferences.toml)
# and edited on the Settings page of the GUI.

const SERIAL_PORT_PREFERENCE_KEY = "serial_port"
const VOLUME_UNIT_PREFERENCE_KEY = "volume_unit_uL"   # 10 for ÄKTAprime plus, 1 for ÄKTAprime
const DEMO_MODE_PREFERENCE_KEY = "demo_mode"
const LOG_PREFIX_PREFERENCE_KEY = "log_prefix"

mutable struct Settings
    demo_mode::Bool          # simulated data instead of the instrument
    serial_port::String
    volume_unit_uL::Float64  # µL per volume count
    log_prefix::String       # CSV files are named <prefix>_<date>_<time>.csv
end

load_settings() = Settings(
    @load_preference(DEMO_MODE_PREFERENCE_KEY, false),
    @load_preference(SERIAL_PORT_PREFERENCE_KEY, DEFAULT_SERIAL_PORT),
    Float64(@load_preference(VOLUME_UNIT_PREFERENCE_KEY, DEFAULT_VOLUME_UNIT_UL)),
    @load_preference(LOG_PREFIX_PREFERENCE_KEY, "akta"),
)

function save_settings(s::Settings)
    @set_preferences!(
        DEMO_MODE_PREFERENCE_KEY => s.demo_mode,
        SERIAL_PORT_PREFERENCE_KEY => s.serial_port,
        VOLUME_UNIT_PREFERENCE_KEY => s.volume_unit_uL,
        LOG_PREFIX_PREFERENCE_KEY => s.log_prefix,
    )
end
