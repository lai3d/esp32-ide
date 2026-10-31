# ESP32 IDE

A native macOS IDE for MicroPython on ESP32 boards, written in Swift (SwiftUI + AppKit) with no third-party dependencies.
Sibling of [python-ide](https://github.com/lai3d/python-ide): same editor and LSP client, with the local interpreter replaced by a board on a serial port.

> Early MVP: edit, run, upload and browse files on a real board. Tested with an ESP32-D0WD-V3 (CH340) on MicroPython v1.29.

## Features

- **Board connection**: lists USB serial ports (`/dev/cu.usbserial-*`, `cu.usbmodem*`, `cu.SLAB_USBtoUART`, …) and refreshes as boards are plugged in.
  The port is opened exclusively, so another tool (mpremote, Thonny) can't interleave bytes; **Disconnect** frees it.
- **Raw REPL protocol in Swift** (what `mpremote` does): Ctrl-A raw mode, code sent in small chunks, `OK<stdout>\x04<stderr>\x04>` replies, streamed output.
- **Run** (⌘R): runs the current file (or `main.py`) on a freshly soft-reset interpreter without saving it on the board.
  Output streams into the Output panel, `input()` works from the input field, **Stop** (⌘.) sends Ctrl-C.
- **REPL panel**: the board's interactive REPL. ↑/↓ history, Ctrl-C, soft reset (Ctrl-D, re-runs `main.py`).
  **Send Selection to REPL** (⌃↩) uses paste mode, so indented blocks survive.
- **Board files** (sidebar, chip icon): the board's flash as a tree with sizes. Click to open a read-only copy;
  right-click to download into the project or delete.
- **Upload** (⌘U) the current file to the same path on the board; **Sync** (⇧⌘S) uploads every changed `.py`/`.json` file of the project.
  Unchanged files are skipped by comparing SHA-256 on the Mac and on the board. `docs/`, `tests/`, hidden folders and `*.example.py` are not uploaded.
- **MicroPython completion**: *Python → Install MicroPython Stubs* puts `micropython-esp32-stubs` into
  `~/Library/Application Support/ESPIDE/stubs` (your project is not modified) and points pyright at them, so `machine`, `network`, `neopixel`, …
  complete and type-check against MicroPython's own standard library. Without stubs, unresolved imports are silenced.
- **Flash firmware** (*Board → Flash MicroPython Firmware…*): detect the chip with esptool, download the latest stable image from
  micropython.org (or pick a `.bin`), optionally erase, write at the right offset (0x1000 for ESP32, 0x0 for S2/S3/C3/C6) with a progress bar,
  then reconnect. Uses an installed `esptool`, else `uvx esptool`, else `python -m esptool`.
- **Plot** panel (⌃⌘L): a live chart of numbers the board prints — `print(t)`, `print(t, p)` or `print("t=", t, "p=", p)` (named series).
- **I2C scan** (*Board → Scan I2C Bus…*): scans any SDA/SCL pins and names common parts (0x27 LCD backpack, 0x3C SSD1306, 0x76 BMP280, 0x68 MPU6050, …).
- From PyIDE: tabs, Python highlighting and editing, pyright completion / hover / go to definition / references / rename, Outline, ruff formatting.

## Develop

```sh
swift test                                              # unit tests (fake board)
ESPIDE_TEST_PORT=/dev/cu.usbserial-110 swift test       # plus a round trip against a real board
swift run ESPIDE ~/path/to/micropython/project
scripts/bundle.sh                                       # build/ESPIDE.app (ad-hoc signed)
```

Layout:

- `Sources/ESPIDECore` — UI-independent: `SerialPort` (termios), `MicroPythonDevice` (raw REPL), `DeviceFiles` (list/read/write/hash/delete),
  `ProjectSync`, `Firmware` (esptool commands, micropython.org images), `PlotParser`/`PlotData`, `I2C`, `MicroPythonStubs`,
  plus PyIDE's LSP client and text utilities.
- `Sources/ESPIDE` — the app: `Board` (connection, REPL, run, files), `Workspace`, editor and views.

Requires macOS 14+ and a board already flashed with MicroPython.

## Roadmap

- Pin usage map (which GPIOs a project uses, boot-strapping and ADC2 warnings)
- Edit board files in place; install libraries with `mip`
- ESP-IDF projects (`idf.py build/flash/monitor`)
