# AktaPrime.jl

[![Documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://waudbylab.github.io/AktaPrime.jl/dev/)
[![CI](https://github.com/waudbylab/AktaPrime.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/waudbylab/AktaPrime.jl/actions/workflows/CI.yml)
[![Documentation build](https://github.com/waudbylab/AktaPrime.jl/actions/workflows/Documenter.yml/badge.svg)](https://github.com/waudbylab/AktaPrime.jl/actions/workflows/Documenter.yml)

AktaPrime is a Julia app for logging and visualising GE/Cytiva **ÄKTA Prime plus**
chromatography data — an open replacement for the discontinued PrimeView control
software.

> **Disclaimer.** AktaPrime.jl is an **independent, unofficial** project. It is
> **not affiliated with, authorised, endorsed, or supported by Cytiva** (formerly
> GE Healthcare) or any related entity. "ÄKTA", "ÄKTA Prime", "PrimeView" and
> "UNICORN" are trademarks of their respective owners and are used here only to
> identify the hardware and software with which this project interoperates.

![AktaPrime screenshot](assets/screenshot.png)

## Documentation

Full user documentation — installation (including the serial cable and
per-platform serial-port setup), running an acquisition, viewing and exporting
results, and demo mode — is at:

**➡ https://waudbylab.github.io/AktaPrime.jl/dev/**

Quick links:

- [Installation](https://waudbylab.github.io/AktaPrime.jl/dev/installation/)
- [Acquisition](https://waudbylab.github.io/AktaPrime.jl/dev/acquisition/)
- [Viewing results](https://waudbylab.github.io/AktaPrime.jl/dev/viewing/)
- [Demo mode](https://waudbylab.github.io/AktaPrime.jl/dev/demo/)

## Requirements

- Julia 1.12+
- A serial (RS-232) connection to the instrument — see the
  [installation docs](https://waudbylab.github.io/AktaPrime.jl/dev/installation/)
  for the recommended FTDI cable
- `~/.julia/bin` on your `PATH`

On macOS/Linux:

```bash
export PATH="$HOME/.julia/bin:$PATH"
```

## Install as an app

In Julia package mode:

```julia
pkg> app add AktaPrime
```

Or install directly from the repository:

```julia
pkg> app add https://github.com/waudbylab/AktaPrime.jl.git
```

## Run

After installation, use the app command directly:

```bash
AktaPrime
```

This starts with the saved/default serial connection and falls back to demo mode if unavailable.

Use an explicit serial port:

```bash
AktaPrime /dev/tty.usbserial-110
```

Passing a serial path updates the saved serial-port preference.

Open a CSV log file in replay mode:

```bash
AktaPrime run_log.csv
```

## Update / Remove

```julia
pkg> app up AktaPrime
pkg> app rm AktaPrime
```

## Local Development

From this repository checkout:

```bash
julia --project=. -m AktaPrime
julia --project=. -m AktaPrime /dev/tty.usbserial-110
julia --project=. -m AktaPrime akta_demo_20260518_112542.csv
```
