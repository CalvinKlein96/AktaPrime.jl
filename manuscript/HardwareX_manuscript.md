# AktaPrime.jl: an open-source control and data-acquisition client that restores a failed ÄKTA Prime plus FPLC to service

> **First draft for review — HardwareX Original Software Publication.**
> British English throughout. Placeholders are marked `⟦LIKE THIS⟧` and
> collect everything that must come from the authors or from a chosen
> validation run. Nothing in the technical sections has been invented: every
> protocol detail, constant and confirmed scaling is drawn from the
> repository's own decompilation reference (`assets/akta_decompilation_reference.md`),
> protocol specification (`assets/PROTOCOL.md`) and source code. Where the
> repository itself records something as unverified or "to be confirmed", the
> draft says so rather than papering over it.

---

## Author list

⟦AUTHORS AND ORDER — to be supplied. Provide full names, ORCID iDs, and
mark the corresponding author.⟧

⟦AFFILIATIONS — to be supplied and keyed to authors.⟧

Corresponding author e-mail: ⟦c.waudby@ucl.ac.uk? confirm⟧

---

## Abstract

The ÄKTA Prime plus is a benchtop fast protein liquid chromatography (FPLC)
system that was sold in large numbers to protein-science and teaching
laboratories. It is controlled from an external PC running the discontinued
PrimeView software over an RS-232 serial link; the instrument itself carries
no independent data display beyond a small front panel. As the original
Windows control PCs age and fail, and as PrimeView installers become
increasingly difficult to obtain and to run on modern operating systems,
otherwise fully functional instruments are being retired for want of a
working controller rather than for any fault in their fluidics or detectors.

We describe AktaPrime.jl, an open-source client written in Julia that
re-implements the PC side of the ÄKTA Prime serial protocol and provides live
monitoring, event logging, method-progress visualisation and data export as a
drop-in replacement for PrimeView's monitoring function. The serial protocol
was reconstructed by decompiling the vendor's own driver and communication
stack for interoperability purposes and cross-checking the result against a
physical instrument. The software presents a real-time chromatogram (UV,
conductivity, gradient %B and pressure), a schematic of the current flow path,
fraction-collection tracking and an on-disk comma-separated-value (CSV) log
that can be re-opened for offline review. We demonstrate the client with a
protein purification run performed entirely under its control, and discuss
both what this establishes — that the reconstructed protocol drives real
separations and captures correct data — and its principal limitation, namely
the absence of a simultaneous parallel recording on the original vendor
software against which to benchmark quantitatively.

**Keywords:** FPLC; ÄKTA Prime; protein purification; laboratory instrument
control; right to repair; reverse engineering; interoperability; RS-232;
open-source scientific software; Julia.

---

## Specifications table

| | |
|---|---|
| Hardware name | AktaPrime.jl — open-source control/acquisition client for the GE/Cytiva ÄKTA Prime plus FPLC |
| Subject area | Biological sciences (protein purification / chromatography); laboratory instrumentation; scientific software |
| Hardware type | Instrument control and data-acquisition software; serial-protocol client for existing laboratory hardware |
| Closest commercial analog | GE/Cytiva **PrimeView** control software (discontinued) running on a dedicated Windows PC |
| Open-source license | ⟦LICENCE TO BE CHOSEN — see tidy-up plan; recommend an OSI-approved licence such as MIT or Apache-2.0 for the code, with the article under CC-BY per HardwareX policy⟧ |
| Cost of hardware | No new hardware required beyond the existing ÄKTA Prime plus and a host computer; a USB-to-RS-232 adaptor (≈ ⟦£15–30 / confirm⟧) is needed where the host lacks a native serial port |
| Source file repository | https://github.com/waudbylab/AktaPrime.jl ⟦make public before submission; archive a release DOI, e.g. via Zenodo⟧ |

### Software metadata table

| | |
|---|---|
| Current code version | v0.1.0 (`Project.toml`) |
| Permanent link to code/repository | https://github.com/waudbylab/AktaPrime.jl ⟦+ archived DOI⟧ |
| Legal code licence | ⟦TO BE ADDED — no LICENSE file currently in the repository⟧ |
| Code versioning system | git |
| Software code language / tool | Julia (≥ 1.12) |
| Compilation requirements, operating environments and dependencies | Julia ≥ 1.12; packages GLMakie (0.13.10), LibSerialPort (0.5.2), Observables (0.5.5), Preferences (1.5.2), plus the standard libraries Dates, Logging and Printf. A physical serial connection (native RS-232 or USB-to-serial adaptor) to the instrument for live use; none for replay or demonstration mode. |
| If available, link to developer documentation / manual | Repository `README.md`; protocol and decompilation notes under `assets/` |
| Support e-mail | ⟦SUPPORT CONTACT — to be supplied⟧ |

---

## 1. Motivation and hardware in context

The ÄKTA Prime plus is a self-contained benchtop FPLC system: it integrates a
gradient pump, injection valve, sample loop, column position, in-line UV and
conductivity monitors, a pressure sensor and an outlet/fraction-collector
valve. Unlike a modern ÄKTA instrument, the Prime has no on-board computer or
graphical interface of its own; it is driven and monitored entirely from an
attached PC over a 9600-baud RS-232 serial line, using the vendor's PrimeView
software (part of the wider UNICORN control-software family). The instrument
carries only a small front-panel display, so without a working PC-side
controller the operator loses live chromatogram display, event logging, method
progress and, in practice, convenient data capture.

This architecture creates a single, brittle point of failure. The fluidics,
optics and detectors of a Prime are robust and readily serviced, and many
instruments remain mechanically sound well beyond the lifetime of their
original control PCs. Those PCs, however, run legacy Windows versions and a
software stack of the Windows-95 era; when the PC dies, or its hard disk fails,
or an institutional upgrade removes it, the laboratory is frequently left with
a functioning instrument and no way to talk to it. The PrimeView installer is
no longer straightforward to obtain or to license, and running it on
contemporary hardware and operating systems is unreliable.

The resulting user need is real and evidenced. Requests for PrimeView
installers, licence workarounds, and advice on running the software under
compatibility layers recur on community resources such as the WineHQ
application database and the LabWrench instrument-support forums,
⟦CITE the specific WineHQ AppDB entry/entries and LabWrench threads consulted;
give URLs and access dates⟧ where users describe exactly this predicament: a
healthy ÄKTA Prime with a dead or missing controller. This is a
sustainability and right-to-repair problem before it is a software problem. A
capital instrument that separates proteins perfectly well is scrapped, or left
idle, not because any wetted or optical component has failed but because a
commodity PC and a piece of unsupported software are no longer available. The
environmental and financial cost of replacing such an instrument is
substantial and entirely avoidable.

There is also an accessibility argument. ÄKTA Prime systems are common on the
second-hand market and in under-resourced and teaching laboratories precisely
because they are affordable and reliable. For exactly these users — who are
least able to absorb the cost of a new instrument or a vendor service
contract — a free, open, cross-platform controller that runs on any ordinary
laptop lowers the barrier to keeping an instrument in productive use and to
teaching chromatography hands-on.

AktaPrime.jl addresses this need by re-implementing the PC side of the ÄKTA
Prime serial protocol as an open-source Julia application. It restores the
monitoring capability that PrimeView provided — live multi-channel
chromatogram, run-state and event tracking, fraction bookkeeping and data
logging — without any dependency on the vendor software or on a particular
operating system.

### 1.1 Legal basis for the reverse-engineering work

The PC-side protocol was reconstructed by decompiling the vendor's own driver
and communication components (see Section 3). This work was undertaken solely
to achieve interoperability with hardware the laboratory already owns and
which the vendor no longer supports, and not to circumvent any technical
protection measure or to reproduce the vendor's software. Decompilation
carried out for the purpose of achieving interoperability of an independently
created program with existing hardware or software is a recognised exemption
within UK and EU software-copyright law (in the United Kingdom, the
decompilation provisions of the Copyright, Designs and Patents Act 1988 as
amended; in the European Union, the corresponding provisions of the Software
Directive 2009/24/EC, Article 6). ⟦Legal framing to be reviewed/approved by
the authors and, if appropriate, an institutional adviser before submission.⟧

---

## 2. Hardware and software description

### 2.1 What the software is

AktaPrime.jl is a single, installable Julia application. On launch it opens (or
falls back to a simulated demonstration of) the serial link to an ÄKTA Prime,
prompts for a log-file name, and presents a live graphical display of the run.
It has three operating modes, selected by the single command-line argument:

- **Live mode** — connects to the instrument on a named serial port,
  streams and decodes instrument data in real time, logs to CSV and displays
  the run.
- **Demonstration mode** — entered automatically when no instrument is
  reachable; synthesises a plausible chromatographic data stream so that the
  interface can be exercised, taught and screenshotted without hardware.
- **Replay mode** — re-opens a previously written CSV log and reconstructs
  the full display, including events and fraction spans, for offline review.

### 2.2 The display

The graphical interface (Figure 1) is built with GLMakie and is organised as
four vertically stacked, x-axis-linked chromatogram panels on the left and a
status-and-schematic column on the right.

- The panels show **UV absorbance (AU)**, **gradient %B**, **conductivity
  (mS/cm)**, **pH** and **pressure (MPa)**, sharing a common x-axis. UV is
  always shown; the other four panels can be shown or hidden individually from
  a set of toggles, so the display can be pared down to the channels of
  interest.
- A menu switches the shared x-axis between **elapsed time (minutes)** and
  **cumulative volume (mL)**, the two natural abscissae for a chromatogram.
- Each time a new run begins, the client automatically starts a fresh log file
  and clears the display, so successive runs do not overlay one another when
  the acquisition window is left open across runs.
- Instrument **events** — connect/disconnect, run-state changes, injection-
  valve movements, method steps and free-text log messages from the
  instrument — are drawn as labelled vertical markers on the UV panel.
- **Fraction-collection periods** are shaded as coloured spans across the UV
  and %B panels and numbered, so that peaks can be read directly against the
  tubes they were collected into.
- The right-hand **status panel** reports run state, elapsed run time and
  volume, injection-valve position, current output routing (fraction collector
  or waste), fraction number and size, the instrument's reported programme name
  and version, and the active log-file name.
- A **flow-path schematic** beneath the status panel redraws itself live to
  show the current routing of buffer A/B through the mixer, injection valve,
  sample loop, column, detector and outlet valve, colour-coded by the current
  %B and valve state. This gives the operator an at-a-glance picture of where
  liquid is going that the original front panel does not provide.

**Figure 1.** ⟦Screenshot — `assets/screenshot.png`. Replace the caption below
with a figure showing a real run rather than demonstration data if one is
available.⟧ *AktaPrime.jl running in demonstration mode. Left: linked UV, %B,
conductivity and pressure panels with event markers and numbered
fraction-collection spans. Right: live status read-out and a flow-path
schematic that redraws itself according to the current valve and gradient
state.*

### 2.3 Data captured

Every decoded trend sample and every discrete event is appended immediately to
a flat CSV file, which is flushed after each row so that a crash or power loss
loses at most the current sample. The log carries a header comment with the
start timestamp, then rows with the columns:

```
wall_time, cum_time_ms, cum_vol_mL, type,
uv_AU, cond_mScm, ph, pctb_pct, pres_MPa, temp_degC, message
```

Trend rows carry the six sensor channels against cumulative run time and
volume; event rows carry a type tag (connect, disconnect, run-state, inject,
tube-feed, log, step) and a free-text message. Because the file is plain CSV,
it is trivially importable into any downstream analysis tool, and the same file
re-opened in replay mode reproduces the original display exactly.

### 2.4 Capabilities and limitations of scope

AktaPrime.jl re-implements the **monitoring** role that PrimeView performs in
normal use. This is a deliberate and well-founded scope choice: the
decompilation established that PrimeView (`Csyscon.exe`) is itself a
monitoring-only client, which in normal operation sends no commands to the
instrument and only receives its event stream (Section 3). The ÄKTA Prime is
operated from its own front-panel controls and templates; the PC's job is to
watch, display and record. AktaPrime.jl therefore reproduces the part of the
vendor workflow that laboratories actually depend on day to day.

The client does not (yet) parse the binary method (`.met`) file that the
instrument can dump over the link, and so it does not reconstruct the full
programmed method or the instrument's *initial* valve state at connect time;
these are known to be embedded in that file, whose format has not been reversed
(Section 3.4). Valve and fraction state are instead tracked from the
instrument's own log messages and event frames as the run proceeds.

---

## 3. Methodology: how the protocol was reverse-engineered

The PC-side protocol is not publicly documented. It was reconstructed by static
decompilation of the vendor's UNICORN/PrimeView software stack, guided at every
step by the constraint that the result had to reproduce the behaviour of a
physical instrument. The full working notes are retained in the repository
(`assets/akta_decompilation_reference.md` and `assets/PROTOCOL.md`); this
section summarises the method and the key findings.

### 3.1 Components analysed

The following binaries from the ÄKTA Prime UNICORN stack (Windows-95 vintage)
were decompiled and cross-referenced:

- `p232_drv.exe` — the RS-232 serial driver process;
- `Orqoci.dll` — the OCI protocol client and named-pipe transport;
- `Comiface.dll` — a thin wrapper over `Orqoci`;
- `Oci.exe` — the OCI server that launches the driver and brokers clients;
- `AInstrInfo.dll` — instrument/hardware detection and parameter tables;
- `Caktacal.dll` — calibration computation;
- `Csyscon.exe` — the PrimeView GUI client itself.

### 3.2 Reconstructing the process and transport architecture

Decompilation first established how the vendor stack is layered. `Oci.exe`
creates a set of named pipes and mailslots and launches `p232_drv.exe` as a
child process; `p232_drv.exe` owns the serial port and bridges it to the pipe
layer; PrimeView and up to eight other UNICORN clients attach as pipe clients
to receive the event stream. Within `p232_drv.exe`, a dedicated link-layer
thread (`thdLinklayer`) runs the serial state machine, a control thread
(`thdControl`) runs the higher-level OPC (operation-code) protocol state
machine, and further threads forward events upstream. Mapping these threads,
the mailslots that connect them (`STATUSX`, `TX_DWNLOADX`, `RX_UPLOADX`,
`ONLINEX`) and their message codes made it possible to separate the two things
that matter for an independent client — the on-the-wire *serial* protocol and
the internal *IPC* plumbing — and to discard the latter.

A pivotal finding at this stage was that PrimeView is a **monitoring-only**
client. Tracing `Csyscon.exe`'s connection sequence showed that it calls the
receive-side functions (`comConnectSystem`, `comStartEventReciever`) but never
the command-sending functions (`comAppendManualString`, `comSetSystemState`,
`comSetSystemSettings` and the like are imported but never called). The only
instrument command it can emit at all is confined to a non-standard AKTAxpress
run mode. This established that a faithful, useful replacement client need only
implement the serial link and the instrument-to-PC half of the protocol — it
does not need to reproduce the pipe servers or the command path.

### 3.3 The serial link layer

The serial protocol is a lightweight HDLC-like sliding-window scheme (window
size one, sequence numbers modulo four) carried entirely in printable ASCII at
9600 baud, 8N1. The PC is always master: it polls, and the instrument responds;
there are no unsolicited transmissions from the instrument.

Every frame has the form

```
'#'  <addr>  <ctrl>  <payload…>  <checksum>  CR
```

where the address byte is `'0'` (0x30) for PC-originated frames and `'1'`
(0x31) for instrument-originated frames, and the control byte encodes the frame
type (poll/SNRM, unnumbered acknowledgement, receive-ready, or information
frame) together with the send and receive sequence numbers. The checksum,
recovered from `computeChecksum` in the driver, is an 8-bit wrapping sum over
the frame body folded into printable range:

```julia
function checksum(bytes)
    s = zero(UInt8)                 # 8-bit accumulator; wraps by construction
    for b in bytes
        s += b
    end
    ((s + (s >> 6)) & 0x3f) + 0x30  # fold to a printable ASCII byte
end
```

Two subtleties were confirmed against the decompiled builder/validator
functions and are essential to interoperating: the accumulator is genuinely
8-bit and wraps (no widening before the fold), and the receive-number field
follows a **non-standard convention** — it carries the sequence number of the
*last successfully received* information frame, not the *next expected* one as
in textbook HDLC. Getting either wrong produces frames the instrument silently
rejects.

The connection handshake, likewise recovered from the driver and then
confirmed end-to-end against hardware, is: the PC sends poll/SNRM frames
(`#0S5\r`, bytes `23 30 53 35 0D`) at roughly 100 ms intervals until the
instrument answers with an unnumbered acknowledgement (`#1uX\r`,
`23 31 75 58 0D`); both sides then reset their sequence numbers, and the PC
sends a connect information frame carrying operation code `0x1001` with data
byte `0x01`. In the full vendor stack this is preceded by a `0x1001/0x00`
frame that the instrument ignores while disconnected; for a standalone client
that preceding frame can be omitted. The instrument then replies with its
programme name (`0x8001`) and version (`0x8002`), after which it streams data.

### 3.4 The application (OPC) layer

Frame payloads carry one or more OPC messages, each a four-character encoded
header (operation code and byte count) followed by data encoded six bits per
character (three characters per two bytes for binary messages; pass-through for
ASCII messages). Decoding these encodings from `buildTxFrame` and
`parseRxDataFrame`, and then decoding each instrument-to-PC message body from
its handler, yielded the message set the client implements. The
instrument-to-PC messages of interest are:

- `0x2001` **TrendDelta** (14 bytes) — the core streaming sample: incremental
  time and volume plus six packed sensor channels (UV, conductivity, pH, %B,
  pressure, temperature) at various bit-widths;
- `0x2002` **TrendAbsolute** (8 bytes) — resets the cumulative time/volume
  base;
- `0x2003` **RunState** (10 bytes) — run time, run volume, run state
  (End/Run/Pause/Hold/Continue) and inject-valve activity;
- `0x2004`/`0x2005` **Inject/TubeFeed** — precisely time-stamped injection and
  fraction-tube events (the tube number travels in `0x2005`);
- `0x2006` **step time/volume**; `0x8001`/`0x8002` **programme name/version**;
- `0x8003` **debug text**; `0x8004`–`0x8007` **log messages** (single frame,
  or begin/middle/end for long messages), which carry human-readable strings
  such as `Injection Valve Load`, `Fraction size 2 ml` and `Feed Tube Nr 10`.

An important semantic point recovered from `handleInjectTubefeed` and
`handleLogMessage` is that the **injection-valve position is not encoded in any
binary frame**: the binary inject/tube-feed frames provide only a timestamp and
volume, while the valve's actual position (Load/Inject/Waste) is conveyed
solely by the accompanying free-text log message. AktaPrime.jl therefore
derives valve and fraction state by parsing those log strings, exactly as the
vendor stack does. The instrument's *initial* valve position and the full
programmed method are not sent as log messages at all; they are embedded in the
binary method (`.met`) dump (`0x2007`/`0x8008`/`0x8011`/`0x2008`), whose file
format has not been reversed and which the client does not currently parse.

### 3.5 Sensor scaling and its validation against hardware

The decompilation recovered the bit-level extraction of each sensor channel
and the vendor's implied decimal scaling. A key finding, confirmed from the
calibration analysis (`Caktacal.dll`) and from the fact that PrimeView displays
the same numbers as the instrument's own LCD without further transformation, is
that the ÄKTA Prime applies calibration **internally in its own firmware**: the
values in trend frames already arrive in engineering units. The client
therefore needs only to apply the fixed decimal scaling, not any calibration
model.

The scalings are not merely inferred from code; several were confirmed against
a physical instrument during testing recorded in the repository as **May 2025**
(`assets/akta_decompilation_reference.md`, "Confirmed from physical testing"):

- UV ÷ 1 000 000 matches the front-panel reading;
- conductivity ÷ 1000 → mS/cm matches the front panel;
- temperature (raw − 100) ÷ 10 → °C matches the front panel (2.5 °C observed);
- %B ÷ 10 matches the front panel (106 raw → 10.6 %B observed);
- the volume-delta unit is 10 µL per count;
- the full `0x1001/0x00 → 0x8001 → 0x8002 → 0x1001/0x01` handshake, and
  immediate trend streaming thereafter, were confirmed end-to-end.

Two channels warrant an explicit note on confidence. The pressure channel is
in **MPa** (raw ÷ 1000); the client decodes, plots and logs it as such. The pH
channel is decoded with the documented scaling (raw ÷ 100) to a dimensionless
pH and is now captured and displayed on its own panel, but that scaling has not
yet been checked against a reference buffer on an electrode-equipped
instrument, so it should be treated as provisional until confirmed. Because the
serial channel table always carries a pH field whether or not an electrode is
fitted, presence of a genuine pH signal is a property of the instrument
configuration rather than of the protocol. ⟦If the pH scaling has since been
confirmed against known buffers on the authors' instrument, update this
paragraph accordingly.⟧

---

## 4. Design files summary

AktaPrime.jl is software, so the "design files" are its source modules and its
protocol documentation. The repository layout is:

| File | Type | Open-source licence | Location / description |
|---|---|---|---|
| `src/AktaPrime.jl` | Julia source | ⟦licence⟧ | Module entry point; mode selection (live/replay), demo generator, serial-port preference handling, main run loop |
| `src/types.jl` | Julia source | ⟦licence⟧ | Core data types (`TrendPoint`, `Fraction`, `AktaEvent`, `InstrumentState`, `AppState`) and the fraction-tracking state machine |
| `src/protocol.jl` | Julia source | ⟦licence⟧ | Serial link layer, frame build/validate, OPC encode/decode, and per-OPC handlers |
| `src/csv_writer.jl` | Julia source | ⟦licence⟧ | CSV logging (flushed per row) and the CSV reader used by replay mode |
| `src/gui.jl` | Julia source | ⟦licence⟧ | GLMakie display: linked chromatogram panels, event markers, fraction spans, status panel and live flow-path schematic |
| `Project.toml` / `Manifest.toml` | Package metadata | ⟦licence⟧ | Dependency specification and a fully resolved environment (Julia 1.12.2) |
| `assets/PROTOCOL.md` | Documentation | ⟦licence⟧ | Complete ÄKTA Prime RS-232 protocol specification recovered by this work |
| `assets/akta_decompilation_reference.md` | Documentation | ⟦licence⟧ | Function-level decompilation reference, including confirmed-vs-unverified findings |
| `assets/screenshot.png` | Image | ⟦licence⟧ | Interface screenshot |
| `README.md` | Documentation | ⟦licence⟧ | Installation and usage instructions |

⟦Add a `LICENSE` file and a `CITATION.cff`; see the tidy-up plan. The licence
column above cannot be completed until a licence is chosen.⟧

---

## 5. Build and installation instructions

### 5.1 Prerequisites

- **Julia ≥ 1.12** (the development environment resolves to 1.12.2). Install
  from the official distribution or via `juliaup`.
- **A serial connection to the instrument** for live use: either a native
  RS-232 port or a USB-to-RS-232 adaptor. No serial hardware is needed for
  demonstration or replay mode.
- Ensure `~/.julia/bin` is on your `PATH` so that the installed application
  command is found. On macOS/Linux:

  ```bash
  export PATH="$HOME/.julia/bin:$PATH"
  ```

### 5.2 Install as an application

From the Julia package REPL (press `]`), install the app directly from the
repository:

```julia
pkg> app add https://github.com/waudbylab/AktaPrime.jl.git
```

⟦These instructions currently assume a **private** repository and mention
authenticating with credentials that can read it. Before publication the
repository should be made public and this step simplified; see the tidy-up
plan.⟧

This places an `AktaPrime` launcher on your `PATH`. Update or remove it with:

```julia
pkg> app up AktaPrime
pkg> app rm AktaPrime
```

### 5.3 Run from a source checkout (for development)

```bash
julia --project=. -m AktaPrime                       # live/demo
julia --project=. -m AktaPrime /dev/tty.usbserial-110  # explicit serial port
julia --project=. -m AktaPrime run_log.csv           # replay a log
```

---

## 6. Operation instructions

### 6.1 Connecting to an instrument

1. Connect the host to the ÄKTA Prime's serial port (directly or via a
   USB-to-serial adaptor) and power on the instrument.
2. Launch the application with the serial device path:

   ```bash
   AktaPrime /dev/tty.usbserial-110
   ```

   The device path is remembered as a preference, so subsequent launches can
   omit it:

   ```bash
   AktaPrime
   ```
3. The client polls for the instrument and, on connecting, records a connect
   event. If no instrument is reachable within the timeout, it drops into
   demonstration mode automatically so the interface can still be explored.
4. When prompted, accept the default timestamped log-file name or type your
   own. Logging begins immediately and the display window opens.

### 6.2 During a run

- Operate the ÄKTA Prime from its own front panel as usual. AktaPrime.jl
  watches and records; it does not drive the separation.
- Use the **X-axis units** toggle to read the chromatogram against time or
  against volume.
- Watch the **status panel** for run state, valve position and
  fraction-collection routing, and the **flow-path schematic** for a live
  picture of where liquid is flowing.
- Fraction spans and event markers accumulate on the chromatogram as the run
  proceeds, so peaks can be matched to collected tubes in real time.

### 6.3 Ending a run and reviewing data

- Close the window (or press Ctrl-C in the terminal) to stop logging cleanly;
  the client reports how many trend points were written and closes the CSV.
- Re-open any saved log for offline review — with all events and fraction
  spans reconstructed — by passing it as the argument:

  ```bash
  AktaPrime akta_20260518_121556.csv
  ```

### 6.4 Demonstration mode (teaching / evaluation)

Launch with no reachable instrument (or simply on a machine with no serial
hardware) to enter demonstration mode, which synthesises a chromatogram with
gradient, peaks, valve changes and fraction collection at roughly ten times
real speed. This is useful for teaching, for evaluating the interface, and for
producing figures without tying up an instrument.

---

## 7. Validation and characterisation

### 7.1 What was validated, and how

Validation of AktaPrime.jl has two strands. The first, described in Section 3.5,
is **protocol-level**: individual sensor scalings and the connection handshake
were confirmed against a physical ÄKTA Prime in May 2025 by comparing decoded
values with the instrument's own front-panel read-outs (UV, conductivity,
temperature and %B all matched; the handshake and immediate trend streaming
were reproduced end-to-end). This establishes that the reconstructed protocol
is decoded correctly at the level of individual numbers.

The second strand is a **functional, whole-run demonstration**: a complete
protein purification carried out with the instrument under AktaPrime.jl's
monitoring, to show that the client operates stably for the duration of a real
separation, tracks method progress and events, and captures a coherent
chromatogram and fraction record.

**⟦VALIDATION RUN — to be selected and inserted by the authors.⟧** Please
choose the run(s) to feature and supply, for each:

- what was purified (protein/tag, column and chemistry, buffers,
  gradient/programme);
- the resulting chromatogram (UV, conductivity, %B, pressure), exported or
  screenshotted from AktaPrime.jl, and the corresponding CSV log to deposit
  with the article;
- which fractions were collected and, if assessed, downstream evidence that the
  target was recovered (e.g. an SDS-PAGE gel of pooled fractions).

Suggested caption once chosen:

> **Figure 2.** ⟦Chromatogram of a ⟨protein⟩ purification on an ÄKTA Prime plus
> monitored and logged entirely with AktaPrime.jl. UV (blue), conductivity
> (red) and gradient %B (green) against ⟨time/volume⟩; shaded bands mark
> collected fractions ⟨n–m⟩. Data acquired via the reconstructed serial
> protocol and exported from the client's CSV log.⟧

### 7.2 What this demonstrates

A successful purification monitored end-to-end with AktaPrime.jl demonstrates
that: the reconstructed handshake and streaming protocol sustain a live
connection for the full length of a real run; the decoded UV, conductivity,
gradient and pressure traces are chromatographically sensible and consistent
with the separation performed; run-state, injection-valve and
fraction-collection events are tracked correctly and align with the operator's
actions; and the CSV log is complete and faithfully reproduces the run on
replay. In short, it establishes fitness for the monitoring purpose that
PrimeView served.

### 7.3 What this does *not* demonstrate — stated limitation

There is **no simultaneous parallel recording of the same run on the original
PrimeView software**, and none exists: the instruments on which this work was
carried out no longer have a functioning PrimeView installation, which is the
very circumstance that motivated the project. The validation is therefore a
**functional demonstration, not a controlled quantitative benchmark**. We do
not claim numerical equivalence to PrimeView beyond the point-wise front-panel
comparisons of Section 3.5; we have not, for example, quantified agreement of
peak areas, retention volumes or baseline noise against a vendor-software
recording of the identical run, because no such reference recording is
available. This limitation is intrinsic to the problem being solved and is
stated plainly here and in the Discussion rather than being glossed over. A
future controlled comparison on an instrument that still has a working
PrimeView installation would strengthen the quantitative case (Section 8).

---

## 8. Discussion

AktaPrime.jl shows that an obsolete, PC-tethered laboratory instrument can be
returned to full monitored service with open-source software and no new
hardware, by reconstructing the vendor's serial protocol for interoperability.
The practical payoff is direct: a laboratory whose ÄKTA Prime control PC has
died, or which has acquired a Prime second-hand without usable software, can
run the instrument from any ordinary laptop across operating systems. This is a
concrete instance of the right-to-repair and laboratory-sustainability case —
keeping functional capital equipment in use rather than discarding it over a
dead commodity computer — and it lowers the cost barrier for teaching and
under-resourced laboratories.

Several design choices follow directly from what the decompilation revealed.
Because PrimeView is itself a monitoring-only client, re-implementing only the
receive side is not a shortcut but a faithful reproduction of the vendor
workflow; the instrument is, by design, driven from its own front panel. The
choice to derive valve and fraction state from the instrument's log messages,
rather than from binary frames, likewise mirrors the vendor stack, because the
valve position genuinely exists only in those messages on the wire. The most
significant functional gap — that the programmed method and the initial valve
state, which live in the un-reversed binary `.met` dump, are not reconstructed
— is understood and bounded, and parsing that file is the obvious next
extension.

The principal limitation of the validation is the absence of a
side-by-side comparison against PrimeView, discussed in Section 7.3. It is
worth being clear about why this is acceptable for the claims made: the point
of the work is to *restore a capability that is otherwise entirely absent*, and
against that baseline a demonstrated, stable, correctly decoded purification run
is strong evidence of fitness for purpose. Quantitative equivalence to the
vendor software is a separate and stronger claim that we do not make; it could
be tested in future on an instrument that retains a working PrimeView
installation, or by confirming the two remaining unverified scalings (pH and
the pressure unit) against calibrated references.

More broadly, the artefacts produced here — a documented, function-level
account of the ÄKTA Prime serial and OPC protocols and a working reference
client — lower the barrier for others to build on this hardware: alternative
front ends, integration into laboratory automation, or extension to closely
related instruments in the same UNICORN family. We hope the protocol
documentation in particular is as useful to the community as the client itself.

---

## Declarations

**CRediT author statement.** ⟦To be completed once the author list is fixed.⟧

**Funding.** ⟦FUNDING STATEMENT — to be supplied, or "This research did not
receive any specific grant from funding agencies in the public, commercial, or
not-for-profit sectors."⟧

**Declaration of competing interest.** ⟦To be supplied.⟧

**Acknowledgements.** ⟦Optional — to be supplied.⟧

**Data availability.** The source code, protocol documentation and ⟦the
featured validation run's chromatogram and CSV log⟧ are available in the
repository at https://github.com/waudbylab/AktaPrime.jl ⟦and archived at
DOI ⟧.

**Trademarks.** ÄKTA, ÄKTA Prime, PrimeView and UNICORN are trademarks of their
respective owners (Cytiva / formerly GE Healthcare). This work is independent
and is not endorsed by or affiliated with the trademark holders.

---

## References

⟦REFERENCES — to be supplied. At minimum: (1) the WineHQ AppDB and LabWrench
threads cited in Section 1 as evidence of user need; (2) the UK CDPA 1988
decompilation provisions and EU Software Directive 2009/24/EC referenced in
Section 1.1; (3) the Julia language and the GLMakie/Makie plotting package;
(4) any prior ÄKTA-reverse-engineering or open-FPLC work the authors wish to
position against. Do not fabricate citations — these are placeholders.⟧
