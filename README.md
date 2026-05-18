# AktaPrime.jl

AktaPrime is a Julia app for logging and visualizing AKTA PRIME chromatography data.

![AktaPrime screenshot](assets/screenshot.png)

## Requirements

- Julia 1.12+
- Access to this private repository
- `~/.julia/bin` on your `PATH`

On macOS/Linux:

```bash
export PATH="$HOME/.julia/bin:$PATH"
```

## Install As An App (private repo)

In Julia package mode:

```julia
pkg> app add https://github.com/waudbylab/AktaPrime.jl.git
```

If your GitHub access is SSH-based:

```julia
pkg> app add git@github.com:waudbylab/AktaPrime.jl.git
```

If prompted, authenticate with credentials that can read the private repository.

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
