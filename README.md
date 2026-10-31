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
- From PyIDE: tabs, Python highlighting and editing, pyright completion / hover / go to definition / references / rename, Outline, ruff formatting.
  Unresolved imports are silenced for now, since `machine`, `network` etc. only exist on the board.

## Develop

```sh
swift test                                              # unit tests (fake board)
ESPIDE_TEST_PORT=/dev/cu.usbserial-110 swift test       # plus a round trip against a real board
swift run ESPIDE ~/path/to/micropython/project
scripts/bundle.sh                                       # build/ESPIDE.app (ad-hoc signed)
```

Layout:

- `Sources/ESPIDECore` — UI-independent: `SerialPort` (termios), `MicroPythonDevice` (raw REPL), `DeviceFiles` (list/read/write/hash/delete),
  `ProjectSync`, plus PyIDE's LSP client and text utilities.
- `Sources/ESPIDE` — the app: `Board` (connection, REPL, run, files), `Workspace`, editor and views.

Requires macOS 14+ and a board already flashed with MicroPython.

## Roadmap

- Flash MicroPython firmware (esptool) with a progress bar
- MicroPython stubs for pyright (`micropython-esp32-stubs`) instead of silencing imports
- Serial plotter for numbers a program prints
- I2C scan, pin usage map
- Edit board files in place; ESP-IDF projects (`idf.py build/flash/monitor`)
