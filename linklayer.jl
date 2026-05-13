# linklayer.jl
#
# Julia re-implementation of thdLinklayer (p232_drv.exe @ 0x00405ec0).
#
# Implements the HDLC-like sliding-window protocol (window=1, SN mod 4) used
# by the Akta PRIME UNICORN stack over RS-232.  The PC is always master: it
# polls or transmits and the Akta responds; there are no unsolicited frames.
#
# Usage:
#   tx = Channel{Tuple{UInt16,Vector{UInt8}}}(32)
#   stop = Ref(false)
#   @async run_linklayer(tx, stop)
#   put!(tx, (0x1001, UInt8[0x00]))   # send identity request
#   stop[] = true

using LibSerialPort

# ── Serial port configuration (from openSerialPort @ 0x00404fd0) ─────────────
const SERIAL_PORT = "/dev/tty.usbserial-110"
const BAUD_RATE = 9600    # BuildCommDCBA "9600,n,8,1"

# ── Timing constants (from thdLinklayer loop, GetTickCount pacing) ────────────
const POLL_INTERVAL_MS = 100     # main-loop cadence
const IDLE_TIMEOUT_MS = 5000    # force-disconnect if no valid exchange
const REPLY_TIMEOUT_MS = 500     # give up waiting for Akta reply

# ── Frame byte constants ──────────────────────────────────────────────────────
const FRAME_START = 0x23        # '#' -- all frames start with this
const PC_ADDR = 0x30        # '0' -- PC address byte in outbound frames
const AKTA_ADDR = 0x31        # '1' -- Akta address byte in inbound frames
const FRAME_END = 0x0d        # CR  -- all frames end with this

# ── Control byte constants ────────────────────────────────────────────────────
const CTRL_POLL = 0x53        # poll frame
const CTRL_CONN = 0x75        # Akta connection-response ctrl byte
const CTRL_RR_BASE = 0x30        # ACK/RR ctrl base; OR with (rn & 3)
const CTRL_IFRAME = 0x40        # I-frame ctrl base

# ── OPC codes (from thdControl / parseRxDataFrame dispatch tables) ────────────
const OPC_IDENTITY_REQUEST = UInt16(0x1001)  # PC → Akta: request identity
const OPC_PROG_NAME = UInt16(0x8001)  # Akta → PC: programme name (ASCII)
const OPC_VERSION_STRING = UInt16(0x8002)  # Akta → PC: version string (ASCII)
const OPC_TREND_DATA = UInt16(0x2001)
const OPC_BASE_TIME_VOL = UInt16(0x2002)
const OPC_RUN_STATE = UInt16(0x2003)
const OPC_INJECT = UInt16(0x2004)
const OPC_TUBEFEED = UInt16(0x2005)

# ─────────────────────────────────────────────────────────────────────────────
# LinkState -- mirrors the thread-local variables in thdLinklayer
# ─────────────────────────────────────────────────────────────────────────────
mutable struct LinkState
    connected::Bool
    sn::UInt8           # current TX sequence number mod 4
    rn::UInt8           # last received Akta SN (expected_next = rn+1 mod 4)
    pending_tx::Bool    # true while an I-frame awaits ACK
    idle_ms::Int        # ms since last valid exchange; reset on good reply
    driver_enabled::Bool  # true after OPC 0x1001/0x01 sent (driver-enable gate)
end
LinkState() = LinkState(false, 0x00, 0x00, false, 0, false)

# ─────────────────────────────────────────────────────────────────────────────
# fmt_frame -- format raw frame bytes as "hex  |ascii|" for debug logging
# ─────────────────────────────────────────────────────────────────────────────
function fmt_frame(buf::AbstractVector{UInt8})::String
    hex = join(string.(buf, base=16, pad=2), " ")
    asc = String([0x20 <= b <= 0x7e ? b : UInt8('.') for b in buf])
    return "$hex  |$asc|"
end

# ─────────────────────────────────────────────────────────────────────────────
# compute_checksum  (computeChecksum @ 0x004051e0)
#
# Covers buf[offset .. offset+len-1] (Julia 1-indexed).
# Result = ((sum + (sum >> 6)) & 0x3f) + 0x30, always printable ASCII 0x30–0x6f.
# ─────────────────────────────────────────────────────────────────────────────
function compute_checksum(buf::AbstractVector{UInt8}, offset::Int, len::Int)::UInt8
    s = 0x00
    for i in offset:(offset+len-1)
        s += buf[i]   # UInt8 addition wraps naturally at 256
    end
    return UInt8(((Int(s) + Int(s >> 6)) & 0x3f) + 0x30)
end

# ─────────────────────────────────────────────────────────────────────────────
# validate_rx_frame  (validateRxFrame @ 0x00405210)
#
# Checks '#', Akta address 0x31, CR terminator, and checksum.
# ─────────────────────────────────────────────────────────────────────────────
function validate_rx_frame(buf::AbstractVector{UInt8}, len::Int)::Bool
    len < 5 && return false
    buf[1] != FRAME_START && return false
    buf[2] != AKTA_ADDR && return false
    buf[len] != FRAME_END && return false
    expected = compute_checksum(buf, 2, len - 3)   # addr through last payload byte
    return buf[len-1] == expected
end

# ─────────────────────────────────────────────────────────────────────────────
# build_poll_frame  (buildPollFrame @ 0x004052a0)
#
# Fixed 5-byte frame: 23 30 53 35 0D.  Sent every ~100ms until Akta responds.
# ─────────────────────────────────────────────────────────────────────────────
function build_poll_frame()::Vector{UInt8}
    buf = UInt8[FRAME_START, PC_ADDR, CTRL_POLL, 0x00, FRAME_END]
    buf[4] = compute_checksum(buf, 2, 2)
    return buf
end

# ─────────────────────────────────────────────────────────────────────────────
# build_ack_frame  (buildAckFrame @ 0x004052e0)
#
# Supervisory RR frame; acknowledges an Akta I-frame when TX queue is empty.
# ctrl = 0x30 | (rn & 3).
# ─────────────────────────────────────────────────────────────────────────────
function build_ack_frame(rn::UInt8)::Vector{UInt8}
    buf = UInt8[FRAME_START, PC_ADDR, CTRL_RR_BASE|(rn&0x03), 0x00, FRAME_END]
    buf[4] = compute_checksum(buf, 2, 2)
    return buf
end

# ─────────────────────────────────────────────────────────────────────────────
# build_i_frame  (buildDataFrame @ 0x00405320 + payload encoding from buildTxFrame)
#
# Wraps an already-encoded OPC payload into a full I-frame.
# ctrl = (0x10 | (sn & 3)) << 2 | (rn & 3).
# ─────────────────────────────────────────────────────────────────────────────
function build_i_frame(payload::Vector{UInt8}, sn::UInt8, rn::UInt8)::Vector{UInt8}
    plen = length(payload)
    buf = Vector{UInt8}(undef, plen + 5)
    buf[1] = FRAME_START
    buf[2] = PC_ADDR
    buf[3] = UInt8((0x10 | (sn & 0x03)) << 2 | (rn & 0x03))
    buf[4:3+plen] .= payload
    buf[plen+4] = compute_checksum(buf, 2, plen + 2)
    buf[plen+5] = FRAME_END
    return buf
end

# ─────────────────────────────────────────────────────────────────────────────
# encode_opc_payload  (buildTxFrame @ 0x00405380)
#
# Encodes one (opc, data) pair into the 6-bit ASCII wire format used in I-frames.
#
# Binary OPC (bit 15 = 0):
#   Header byte 0 = ((nob>>1)+0x10)*3 + (nob&1)*2   (encodes # of encoded chars)
#   Data pairs: each 2 bytes → 3 encoded chars; odd last byte → 2 encoded chars.
# ASCII OPC (bit 15 = 1):
#   Header byte 0 = nob + 0x30.  Data bytes passed through verbatim (0x20–0x7f, ≠ '#').
# Header bytes 1-3 encode the OPC value in 6-bit fields.
# ─────────────────────────────────────────────────────────────────────────────
function encode_opc_payload(opc::UInt16, data::Vector{UInt8})::Vector{UInt8}
    out = UInt8[]
    nob = length(data)

    # 4-byte OPC header
    if (opc & 0x8000) == 0
        push!(out, UInt8(((nob >> 1) + 0x10) * 3 + (nob & 1) * 2))
    else
        push!(out, UInt8(nob + 0x30))
    end
    push!(out, UInt8((opc & 0x003f) + 0x30))
    push!(out, UInt8(((opc >> 6) & 0x3f) + 0x30))
    push!(out, UInt8((opc >> 12) + 0x30))

    if (opc & 0x8000) == 0
        # binary encoding: pairs of raw bytes → 3 encoded chars
        i = 1
        while i <= nob
            if i + 1 <= nob
                b0, b1 = data[i], data[i+1]
                push!(out, UInt8((b0 & 0x3f) + 0x30))
                push!(out, UInt8(((b1 & 0x0f) << 2 | (b0 >> 6)) + 0x30))
                push!(out, UInt8((b1 >> 4) + 0x30))
                i += 2
            else
                b0 = data[i]
                push!(out, UInt8((b0 & 0x3f) + 0x30))
                push!(out, UInt8((b0 >> 6) + 0x30))
                i += 1
            end
        end
    else
        # ASCII encoding: passthrough with range check
        for b in data
            if b < 0x20 || b > 0x7f || b == FRAME_START
                @warn "encode_opc_payload: ASCII byte 0x$(string(b, base=16)) out of range, substituting space"
                b = 0x20
            end
            push!(out, b)
        end
    end

    return out
end

# ─────────────────────────────────────────────────────────────────────────────
# decode_opc_payload  (inverse of buildTxFrame encoding; used in parseRxDataFrame)
#
# Decodes the encoded payload from an I-frame back to (opc, raw_data) pairs.
# The payload may contain multiple back-to-back OPC messages (buildTxFrame
# packs up to 3 per frame).  Returns a vector of (opc, data) tuples.
# ─────────────────────────────────────────────────────────────────────────────
function decode_opc_payload(enc::AbstractVector{UInt8})::Vector{Tuple{UInt16,Vector{UInt8}}}
    results = Tuple{UInt16,Vector{UInt8}}[]
    pos = 1
    remaining = length(enc)

    while remaining > 0
        remaining < 4 && break

        nob_byte = enc[pos]
        nob_byte < 0x30 && break           # invalid header
        nob_chars = Int(nob_byte - 0x30)   # encoded char count (binary) or raw nob (ASCII)

        b1 = enc[pos+1]
        b2 = enc[pos+2]
        b3 = enc[pos+3]
        (b1 < 0x30 || b1 > 0x6f) && break
        (b2 < 0x30 || b2 > 0x6f) && break
        (b3 < 0x30 || b3 > 0x3f) && break

        opc = UInt16(b1 - 0x30) | (UInt16(b2 - 0x30) << 6) | (UInt16(b3 - 0x30) << 12)
        pos += 4
        remaining -= 4

        data = UInt8[]
        if (opc & 0x8000) == 0
            # binary decoding: consume nob_chars encoded chars, produce raw bytes
            chars_left = nob_chars
            while chars_left > 0 && remaining > 0
                if chars_left >= 3 && remaining >= 3
                    c0 = Int(enc[pos]) - 0x30
                    c1 = Int(enc[pos+1]) - 0x30
                    c2 = Int(enc[pos+2]) - 0x30
                    push!(data, UInt8(c0 | ((c1 & 0x03) << 6)))
                    push!(data, UInt8(((c1 >> 2) & 0x0f) | (c2 << 4)))
                    pos += 3
                    remaining -= 3
                    chars_left -= 3
                elseif chars_left >= 2 && remaining >= 2
                    c0 = Int(enc[pos]) - 0x30
                    c1 = Int(enc[pos+1]) - 0x30
                    push!(data, UInt8(c0 | ((c1 & 0x03) << 6)))
                    pos += 2
                    remaining -= 2
                    chars_left -= 2
                elseif remaining >= 1
                    c0 = Int(enc[pos]) - 0x30
                    push!(data, UInt8(c0 & 0x3f))
                    pos += 1
                    remaining -= 1
                    chars_left -= 1
                else
                    break
                end
            end
        else
            # ASCII: nob_chars is the raw byte count
            take = min(nob_chars, remaining)
            append!(data, enc[pos:pos+take-1])
            pos += take
            remaining -= take
        end

        push!(results, (opc, data))
    end

    return results
end

# ─────────────────────────────────────────────────────────────────────────────
# handle_trend_data  (handleTrendData @ 0x004030a0, 0x2001 branch)
#
# nob = 14.  Byte layout confirmed from Ghidra decompilation:
#   data[1]        time_delta   uint8, units 10ms
#   data[2]        vol_delta    uint8, units 0.1µl
#   data[3..5]     UV           24-bit signed LE
#   data[6..8]     COND         24-bit unsigned LE
#   data[9]        pH           bits [7:0]
#   data[10]       pH[10:8] at bits[2:0], temp[4:0] at bits[7:3]
#   data[11]       temp[9:5] at bits[4:0], press[2:0] at bits[7:5]
#   data[12]       press[10:3]
#   data[13]       flow[7:0]
#   data[14]       flow[10:8] at bits[2:0]  (bias: raw - 100)
# ─────────────────────────────────────────────────────────────────────────────
function handle_trend_data(data::Vector{UInt8})
    length(data) < 14 && (@warn "OPC 0x2001: short payload ($(length(data)) bytes)"; return)

    time_delta = data[1]  # units: 10ms
    vol_delta  = data[2]  # units: 0.1µl

    uv_raw = Int32(data[3]) | (Int32(data[4]) << 8) | (Int32(data[5]) << 16)
    if (data[5] & 0x80) != 0
        uv_raw |= Int32(-16777216)  # sign-extend bit 23 to Int32
    end

    cond_raw  = UInt32(data[6]) | (UInt32(data[7]) << 8) | (UInt32(data[8]) << 16)
    ph_raw    = Int(data[9])  | ((Int(data[10]) & 0x07) << 8)           # 11-bit
    temp_raw  = (Int(data[10]) >> 3) | ((Int(data[11]) & 0x1f) << 5)   # 10-bit
    press_raw = (Int(data[11]) >> 5) | (Int(data[12]) << 3)             # 11-bit
    flow_raw  = (Int(data[13]) | ((Int(data[14]) & 0x07) << 8)) - 100  # 11-bit, bias -100

    @info "Trend: Δt=$(time_delta * 10)ms Δv=$(round(vol_delta * 0.1; digits=1))µl" *
          "  UV=$uv_raw COND=$cond_raw pH=$ph_raw temp=$temp_raw press=$press_raw flow=$flow_raw"
end

# ─────────────────────────────────────────────────────────────────────────────
# handle_base_time_vol  (handleTrendData @ 0x004030a0, 0x2002 branch)
#
# nob = 8.  Sets (not increments) base time and volume absolutely.
#   data[1..4]   base_time   32-bit LE, units 10ms
#   data[5..8]   base_volume 32-bit LE, units 0.1µl
# ─────────────────────────────────────────────────────────────────────────────
function handle_base_time_vol(data::Vector{UInt8})
    length(data) < 8 && (@warn "OPC 0x2002: short payload ($(length(data)) bytes)"; return)

    base_time = UInt32(data[1]) | (UInt32(data[2]) << 8) | (UInt32(data[3]) << 16) | (UInt32(data[4]) << 24)
    base_vol  = UInt32(data[5]) | (UInt32(data[6]) << 8) | (UInt32(data[7]) << 16) | (UInt32(data[8]) << 24)

    @info "Base time/vol: t=$(base_time * 10)ms vol=$(round(base_vol * 0.1; digits=1))µl"
end

# ─────────────────────────────────────────────────────────────────────────────
# handle_run_state  (handleRunState @ 0x00403340)
#
# nob = 10.  Byte layout confirmed from Ghidra decompilation:
#   data[1..3]   run_time    24-bit LE, /10 → ms   (data[4] unused/padding)
#   data[5..7]   run_volume  24-bit LE, /10 → µl   (data[8] unused/padding)
#   data[9]      state byte  0=End 1=Run 2=Pause 3=Hold 4=Continue
#   data[10]     inject_active (non-zero = active)
#
# OCI state code mapping: 0→6, 1→2, 2→3, 3→4, 4→5 (forwarded to ONLINEX
# as event type 0x3ea in the original; we just log here).
# ─────────────────────────────────────────────────────────────────────────────
const RUN_STATE_NAMES = Dict{UInt8,String}(
    0x00 => "End",
    0x01 => "Run",
    0x02 => "Pause",
    0x03 => "Hold",
    0x04 => "Continue",
)

function handle_run_state(data::Vector{UInt8})
    length(data) < 10 && (@warn "OPC 0x2003: short payload ($(length(data)) bytes)"; return)

    run_time_raw = UInt32(data[1]) | (UInt32(data[2]) << 8) | (UInt32(data[3]) << 16)
    run_vol_raw  = UInt32(data[5]) | (UInt32(data[6]) << 8) | (UInt32(data[7]) << 16)
    state        = data[9]
    inject       = data[10] != 0x00

    state_name = get(RUN_STATE_NAMES, state, "Unknown(0x$(string(state, base=16)))")

    @info "Run state: $state_name  t=$(run_time_raw / 10.0)ms  vol=$(run_vol_raw / 10.0)µl  inject=$inject"
end

# ─────────────────────────────────────────────────────────────────────────────
# dispatch_rx_opc  (mirrors thdControl's RX_UPLOADX message handlers)
#
# On receiving OPC 0x8002 (version string) we queue the driver-enable message
# OPC 0x1001/0x01.  This mirrors thdControl's response to rxUploadMsg==4
# (driver-enable gate fired) which writes {0x1001, [0x01]} to TX_DWNLOADX.
# ─────────────────────────────────────────────────────────────────────────────
function dispatch_rx_opc(opc::UInt16, data::Vector{UInt8}, tx_queue::Channel, st::LinkState)
    if opc == OPC_PROG_NAME
        name = rstrip(String(data[1:min(100, end)]), '\0')
        @info "Akta programme name: $name"
    elseif opc == OPC_VERSION_STRING
        ver = rstrip(String(data[1:min(20, end)]), '\0')
        @info "Akta version: $ver"
        if !st.driver_enabled
            st.driver_enabled = true
            put!(tx_queue, (OPC_IDENTITY_REQUEST, UInt8[0x01]))
            @info "Queued driver-enable (OPC 0x1001/0x01)"
        end
    elseif opc == OPC_TREND_DATA
        handle_trend_data(data)
    elseif opc == OPC_BASE_TIME_VOL
        handle_base_time_vol(data)
    elseif opc == OPC_RUN_STATE
        handle_run_state(data)
    elseif opc == OPC_INJECT
        @info "Inject event: $(length(data)) bytes"
    elseif opc == OPC_TUBEFEED
        @info "Tubefeed event: $(length(data)) bytes"
    else
        @info "OPC 0x$(string(opc, base=16, pad=4)): $(length(data)) bytes"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# parse_rx_data_frame  (parseRxDataFrame @ 0x00405620)
#
# Decodes the payload section of a received I-frame and dispatches each OPC.
# frame: complete raw frame bytes (includes '#', addr, ctrl, cs, CR).
# ─────────────────────────────────────────────────────────────────────────────
function parse_rx_data_frame(frame::AbstractVector{UInt8}, len::Int, tx_queue::Channel, st::LinkState)
    len < 6 && return
    # payload sits between ctrl byte and checksum: frame[4..len-2]
    payload = @view frame[4:len-2]
    for (opc, data) in decode_opc_payload(payload)
        dispatch_rx_opc(opc, data, tx_queue, st)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# write_frame_read_reply  (writeFrameReadReply @ 0x00405cd0)
#
# Sends a frame using the original split-write technique:
#   1. Write all bytes except the last two (checksum + CR)
#   2. Drain the RX buffer (eat any line echo)
#   3. Write the final two bytes
# Then reads the reply byte-by-byte until CR or REPLY_TIMEOUT_MS elapses.
# Returns the received bytes (empty Vector on timeout).
# ─────────────────────────────────────────────────────────────────────────────
function write_frame_read_reply(sp::SerialPort, frame::Vector{UInt8})::Vector{UInt8}
    n = length(frame)

    @debug "TX $(fmt_frame(frame))"

    # split write: send body, drain echo, send checksum + CR
    write(sp, frame[1:n-2])
    sp_flush(sp, SP_BUF_INPUT)
    write(sp, frame[n-1:n])

    # read reply byte-by-byte (mirrors the original ReadFile loop)
    reply = UInt8[]
    in_frame = false
    deadline = time() + REPLY_TIMEOUT_MS / 1000.0

    while time() < deadline
        avail = bytesavailable(sp)
        if avail > 0
            b = read(sp, UInt8)
            if b == FRAME_START
                reply = UInt8[b]
                in_frame = true
            elseif in_frame
                b = (b == 0x0a) ? FRAME_END : b   # normalise LF → CR (mirrors original)
                push!(reply, b)
                b == FRAME_END && break
                length(reply) > 999 && (reply = UInt8[]; in_frame = false)
            end
        else
            sleep(0.001)
        end
    end

    if !isempty(reply)
        @debug "RX $(fmt_frame(reply))"
    end
    return reply
end

# ─────────────────────────────────────────────────────────────────────────────
# run_linklayer  (thdLinklayer @ 0x00405ec0)
#
# Main link-layer loop.  Opens the serial port, polls until the Akta connects,
# then drives the sliding-window exchange.
#
# tx_queue: Channel{Tuple{UInt16,Vector{UInt8}}} — (opc, data) messages to send
# shutdown:  Ref{Bool} — set true for clean exit
# ─────────────────────────────────────────────────────────────────────────────
function run_linklayer(tx_queue::Channel, shutdown::Ref{Bool})
    @info "Opening $SERIAL_PORT at $BAUD_RATE baud"
    sp = LibSerialPort.open(SERIAL_PORT, BAUD_RATE)
    # DTR and RTS high, no CTS/DSR or XON/XOFF flow control (matches DCB flags)
    set_flow_control(sp; rts=SP_RTS_ON, cts=SP_CTS_IGNORE, dtr=SP_DTR_ON, dsr=SP_DSR_IGNORE)

    st = LinkState()
    poll_frame = build_poll_frame()
    cur_frame = poll_frame          # frame currently in the "TX buffer"
    t_last = time_ns()

    @info "Link layer started; polling for Akta"

    try
        while !shutdown[]
            # pace loop to ~100ms (mirrors GetTickCount comparison in thdLinklayer)
            t_now = time_ns()
            elapsed_ms = Int((t_now - t_last) ÷ 1_000_000)
            delay_ms = elapsed_ms < POLL_INTERVAL_MS ? POLL_INTERVAL_MS - elapsed_ms : 1
            sleep(delay_ms / 1000.0)
            t_now = time_ns()
            elapsed_ms = Int((t_now - t_last) ÷ 1_000_000)
            t_last = t_now

            if !st.connected
                # drain stale TX messages while disconnected
                while isready(tx_queue)
                    take!(tx_queue)
                end
                cur_frame = poll_frame

            elseif !st.pending_tx
                st.idle_ms += elapsed_ms

                if isready(tx_queue)
                    opc, data = take!(tx_queue)
                    payload = encode_opc_payload(opc, data)
                    # increment sn before building frame, as in buildDataFrame call site
                    st.sn = (st.sn + 0x01) & 0x03
                    cur_frame = build_i_frame(payload, st.sn, st.rn)
                    st.pending_tx = true
                else
                    cur_frame = build_ack_frame(st.rn)
                end
            else
                st.idle_ms += elapsed_ms
                # pending_tx == true: cur_frame unchanged → retransmit same I-frame
            end

            reply = write_frame_read_reply(sp, cur_frame)
            rx_len = length(reply)

            if rx_len > 0 && validate_rx_frame(reply, rx_len)
                ctrl = reply[3]

                if !st.connected
                    # not connected: look for 5-byte frame with ctrl == 0x75
                    if rx_len == 5 && ctrl == CTRL_CONN
                        @info "Akta connected"
                        st.sn = 0x00
                        st.rn = 0x00
                        st.pending_tx = false
                        st.idle_ms = 0
                        st.connected = true
                        # queue identity request (OPC 0x1001, nob=1, data=0x00 = driver disabled)
                        put!(tx_queue, (OPC_IDENTITY_REQUEST, UInt8[0x00]))
                    else
                        @warn "Unexpected frame while disconnected: ctrl=0x$(string(ctrl, base=16))"
                    end

                else
                    # connected: process I-frame or RR supervisory frame
                    # rx_ok mirrors the original rxOk flag: true only when I-frame SN is correct
                    # (or for RR frames, which have no SN field).  idle_ms is only reset when
                    # rx_ok is true, matching the original `if (rxOk) idle_ms = 0` guard.
                    rx_ok = false

                    if (ctrl & 0xf0) == CTRL_IFRAME
                        received_sn = (ctrl >> 2) & 0x03
                        if received_sn == (st.rn + 0x01) & 0x03
                            st.rn = received_sn
                            parse_rx_data_frame(reply, rx_len, tx_queue, st)
                            rx_ok = true
                        elseif received_sn == st.rn
                            @warn "LinkLayer: same I-frame SN re-received ($received_sn)"
                        else
                            @warn "LinkLayer: SN error — expected $((st.rn+1)&3), got $received_sn"
                        end
                        # check whether Akta ACKed our last outbound I-frame (RN field)
                        if st.sn == (ctrl & 0x03)
                            st.pending_tx = false
                            rx_ok && (st.idle_ms = 0)   # only reset if SN was also good
                        else
                            @warn "LinkLayer: RN mismatch in I-frame ctrl"
                        end

                    elseif (ctrl & 0xfc) == CTRL_RR_BASE
                        # RR supervisory frame (ACK only, no data)
                        if st.sn == (ctrl & 0x03)
                            st.pending_tx = false
                            st.idle_ms = 0   # RR with correct RN is always a clean exchange
                        else
                            @warn "LinkLayer: RN mismatch in RR frame"
                        end

                    else
                        @warn "LinkLayer: unexpected ctrl 0x$(string(ctrl, base=16))"
                    end
                end
            end

            # idle timeout check -- reached every iteration regardless of frame validity,
            # mirroring LAB_004062c0 in the original which is jumped to from all paths
            if st.connected && st.idle_ms > IDLE_TIMEOUT_MS
                @warn "Idle timeout — disconnecting"
                st.connected = false
                st.pending_tx = false
                st.driver_enabled = false
            end
        end

    finally
        @info "Link layer shutting down"
        LibSerialPort.close(sp)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# main
# ─────────────────────────────────────────────────────────────────────────────
function main()
    tx_queue = Channel{Tuple{UInt16,Vector{UInt8}}}(32)
    shutdown = Ref(false)

    # clean exit on Ctrl-C
    Base.exit_on_sigint(false)
    try
        run_linklayer(tx_queue, shutdown)
    catch e
        e isa InterruptException || rethrow()
        @info "Interrupted"
    end
end

main()
