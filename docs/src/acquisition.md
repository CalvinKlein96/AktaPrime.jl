# Acquisition

## Starting the software

Data are written to **the folder you start the app from**, so first open a
terminal and change to wherever you want your files to go:

```bash
cd ~/akta_runs        # or wherever you keep your data
```

Then start the app. If you have already set your serial port (see
[Installation](@ref)), just run:

```bash
AktaPrime
```

To use a specific serial port — or the first time you connect a new
instrument — give the port name:

```bash
AktaPrime /dev/tty.usbserial-110     # macOS
AktaPrime /dev/ttyUSB0               # Linux
AktaPrime COM3                       # Windows
```

The port you give is remembered for next time.

## Setting up the log files

When it starts, the app prints a short summary and asks for a **log-file
prefix**:

```
  Log-file prefix  (press ENTER for "akta"):
```

The prefix is just a label to help you find your files later — a sample name or
your initials work well. Press **ENTER** to accept the default. Each run is then
written to its own file in the current folder, named:

```
<prefix>_<date>_<time>.csv
```

for example `lysozyme_20260714_142530.csv`.

## Running the instrument

Operate the ÄKTA Prime from its **own front panel** as usual — AktaPrime.jl
watches and records, it does not drive the separation. As the run proceeds you
will see:

- the live chromatogram (UV, %B, conductivity, pH and pressure);
- event markers and shaded, numbered fraction-collection spans;
- a status panel and a live flow-path schematic showing the current routing.

## Multiple runs

You do not need to restart the app between runs. **When a new run begins, the
app automatically starts a fresh log file and clears the display**, so
successive runs never overwrite or draw over one another. Each run's data ends
up in its own `<prefix>_<date>_<time>.csv` file.

## Stopping

To stop, simply **close the plot window** (or press `Ctrl-C` in the terminal).
The current log file is closed cleanly, and the app prints where your data was
saved:

```
  Data saved in:
      /Users/you/akta_runs

  Most recent run: lysozyme_20260714_142530.csv
```
