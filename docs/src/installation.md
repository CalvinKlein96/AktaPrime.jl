# Installation

## Hardware requirements

You need three things:

1. A working **ÄKTA Prime plus** instrument.
2. A **computer** running Windows, macOS or Linux.
3. A **serial cable** to connect the two.

### The cable

The ÄKTA Prime is controlled over an **RS-232 serial** connection through a
9-pin (DB-9) serial port on the instrument. This is the single most common
source of trouble, so it is worth getting right:

- Most modern computers no longer have a built-in serial port, so you will
  usually also need a **USB-to-RS-232 adaptor**. Inexpensive adaptors based on
  the FTDI or Prolific chipsets are widely available and work well.
- Connect the adaptor to the instrument with an appropriate RS-232 cable.

!!! warning "Confirm the exact cable type"
    ⟦TODO: confirm and state the exact cable required — in particular whether a
    **straight-through** or a **null-modem (crossover)** DB-9 cable is needed
    between the adaptor and the instrument, and any recommended adaptor. This
    should be filled in from the working setup before release.⟧

The link runs at 9600 baud, 8 data bits, no parity, 1 stop bit; AktaPrime.jl
configures this for you.

## Installing Julia

AktaPrime.jl runs on [Julia](https://julialang.org) version 1.12 or newer.

1. Install Julia — the easiest way is [`juliaup`](https://github.com/JuliaLang/juliaup),
   or download an installer from [julialang.org/downloads](https://julialang.org/downloads/).
2. Make sure the Julia application folder `~/.julia/bin` is on your `PATH`, so
   that installed apps can be run by name. On macOS/Linux, add this to your
   shell profile:

   ```bash
   export PATH="$HOME/.julia/bin:$PATH"
   ```

## Installing AktaPrime

Start Julia, press `]` to enter the package manager, and install the app:

```julia
pkg> app add AktaPrime
```

This puts an `AktaPrime` command on your `PATH`. You can now run it from any
terminal. To update or remove it later:

```julia
pkg> app up AktaPrime
pkg> app rm AktaPrime
```

## Finding and setting the serial port

AktaPrime.jl talks to the instrument through a named serial port. You tell it
which port to use once, and it remembers your choice.

### Windows

1. Open **Device Manager** → **Ports (COM & LPT)**.
2. Find your USB-to-serial adaptor; note its port name, e.g. `COM3`.
3. Start the app with that port:

   ```
   AktaPrime COM3
   ```

### Linux

1. Plug in the adaptor, then list serial devices:

   ```bash
   ls /dev/ttyUSB*      # USB-to-serial adaptors
   ls /dev/ttyS*        # built-in serial ports
   ```

   If unsure which appeared, run `dmesg | tail` right after plugging it in.
2. Start the app with that device:

   ```bash
   AktaPrime /dev/ttyUSB0
   ```

   If you get a permissions error, add yourself to the `dialout` group
   (`sudo usermod -a -G dialout $USER`) and log out and back in.

### macOS

1. List serial devices:

   ```bash
   ls /dev/tty.usbserial-*
   ```
2. Start the app with that device:

   ```bash
   AktaPrime /dev/tty.usbserial-XXXX
   ```

Once set, the port is saved as a preference, so on subsequent runs you can just
type `AktaPrime`.
