# ESP32 IDE

A native macOS IDE for MicroPython and ESP-IDF on ESP32 boards, written in Swift (SwiftUI + AppKit) with no third-party dependencies.
Sibling of [python-ide](https://github.com/lai3d/python-ide): same editor and LSP client, with the local interpreter replaced by a board on a serial port.

> Early MVP: edit, run, upload and browse files on a real board. Tested with an ESP32-D0WD-V3 (CH340) on MicroPython v1.29.

## Features

- **Board connection**: lists USB serial ports (`/dev/cu.usbserial-*`, `cu.usbmodem*`, `cu.SLAB_USBtoUART`, …) and refreshes as boards are plugged in.
  The port is opened exclusively, so another tool (mpremote, Thonny) can't interleave bytes; **Disconnect** frees it.
  *Board → Connect Automatically* connects at launch and whenever a board is plugged in (after a manual Disconnect it waits for a replug).
  Connecting reads the board's files, which stops a running `main.py`; **Reset** starts it again.
- **Raw REPL protocol in Swift** (what `mpremote` does): Ctrl-A raw mode, code sent in small chunks, `OK<stdout>\x04<stderr>\x04>` replies, streamed output.
- **Run** (⌘R): runs the current file (or `main.py`) on a freshly soft-reset interpreter without saving it on the board.
  Output streams into the Output panel, `input()` works from the input field, **Stop** (⌘.) sends Ctrl-C.
- **REPL panel**: the board's interactive REPL. ↑/↓ history, Ctrl-C, soft reset (Ctrl-D, re-runs `main.py`).
  **Send Selection to REPL** (⌃↩) uses paste mode, so indented blocks survive.
- **Board files** (sidebar, chip icon): the board's flash as a tree with sizes. Click to open and edit a file — ⌘S writes it
  back to the board (tabs show `board:/path`). Right-click to download into the project or delete.
- **Install Library…** (*Board* menu): micropython-lib packages (`ssd1306`, `umqtt.simple`, `aioble`, …) with dependencies,
  `github:user/repo/file.py`, or a URL to a `.py`. Like `mpremote mip install`, the Mac downloads the files (checked against the
  index's SHA-256) and copies them to `/lib`, so the board doesn't need Wi-Fi.
- **GPIO usage** (sidebar, last icon): every pin the project uses — `Pin(…)`, `ADC`/`PWM`, driver keywords like `clk=16`, `*_PIN = 25`
  constants — with classic-ESP32 warnings: flash pins 6–11, input-only 34–39 driven as outputs, strapping pins (12!), ADC2 with Wi-Fi,
  UART0, one pin used as two different things. Rules for ESP32, ESP32-S3, ESP32-C3, ESP32-C6 and ESP32-P4, picked from the connected board
  (`sys.implementation._machine`) or chosen in the sidebar. Click a use to jump to it.
- **Upload** (⌘U) the current file to the same path on the board; **Sync** (⇧⌘S) uploads every changed `.py`/`.json` file of the project.
  Unchanged files are skipped by comparing SHA-256 on the Mac and on the board. `docs/`, `tests/`, hidden folders and `*.example.py` are not uploaded.
- **MicroPython completion**: *Python → Install MicroPython Stubs* puts `micropython-esp32-stubs` into
  `~/Library/Application Support/ESPIDE/stubs` (your project is not modified) and points pyright at them, so `machine`, `network`, `neopixel`, …
  complete and type-check against MicroPython's own standard library. Without stubs, unresolved imports are silenced.
- **Flash firmware** (*Board → Flash MicroPython Firmware…*): detect the chip with esptool, download the latest stable image from
  micropython.org (or pick a `.bin`), optionally erase, write at the right offset (0x1000 for ESP32, 0x2000 for P4, 0x0 for S2/S3/C3/C6) with a progress bar,
  then reconnect. Uses an installed `esptool`, else `uvx esptool`, else `python -m esptool`.
- **Board-only modules**: when a module the project imports exists only on the board (a `secrets.py` kept out of git), the board reports its
  public names and types — never values — and ESPIDE writes a `.pyi` stub in its cache so pyright stops flagging `WIFI_SSID` etc.
- **Plot** panel (⌃⌘L): a live chart of numbers the board prints — `print(t)`, `print(t, p)` or `print("t=", t, "p=", p)` (named series).
- **I2C scan** (*Board → Scan I2C Bus…*): scans any SDA/SCL pins and names common parts (0x27 LCD backpack, 0x3C SSD1306, 0x76 BMP280, 0x68 MPU6050, …).
- **ESP-IDF projects** (folders whose `CMakeLists.txt` includes `project.cmake`): the toolbar switches to
  Target / **Build** (⌘B) / **Flash** (⌥⌘R, then opens the serial monitor) / Monitor / Stop, plus *ESP-IDF → Size, Full Clean*.
  GCC errors and warnings go to the Problems panel and are underlined in the editor; C/C++ files get syntax coloring.
  After a build, **clangd** gives C/C++ completion, hover, go to definition, references and rename. It reads a cleaned copy of
  `compile_commands.json` in ESPIDE's cache (response files inlined, GCC-only flags such as `-mlongcalls` removed), so the project
  is not modified and Apple's clangd works with the Xtensa/RISC-V toolchains. *Menuconfig* opens in Terminal.
  `idf.py` comes from a setup script: an `idf-env.sh` in the project or a parent folder, `$IDF_PATH/export.sh`, `~/esp/esp-idf`,
  or one chosen with *ESP-IDF → Choose ESP-IDF…*. Per-project options (`-B build-x -DSDKCONFIG_DEFAULTS="a;b"`) via *Build Options…*.
- **Markdown**: syntax coloring in the editor, and a rendered **Preview** (Source / Preview in the editor header, ⇧⌘V) with headings,
  lists, task lists, code blocks, quotes and tables (column alignment, CJK-aware widths); relative links open in the IDE.
- **Debugging** (⇧⌘D, *Debug* menu, Debug panel): click a line number for a breakpoint (right-click for a condition);
  breakpoints are kept per project. Continue / Step Over (F6) / Step Into (F7) / Step Out (F8), call stack, variables,
  watch expressions and an evaluation console.
  - **MicroPython**: MicroPython on the ESP32 has no `sys.settrace`, so ESPIDE adds a probe in front of every statement
    of the file it runs (on the same line, so tracebacks keep their line numbers) and talks to it over the serial line.
    The probe costs a function call per statement; locals are read only when the program stops. Only the debugged file
    stops (imported modules run normally), `@micropython.native`/`viper` functions aren't probed, and variables can't be
    changed. Stepping over a `return` stops at the next statement anywhere.
  - **ESP-IDF**: OpenOCD + ESP's GDB in DAP mode (`gdb -i dap`), attached on :3333; the chip is reset and runs with the
    breakpoints in place. The S3/C3/C6 use their built-in USB-JTAG; the classic ESP32 needs an adapter such as ESP-Prog.
    **Debug App in QEMU** runs the app in Espressif's emulator (ESP32, S3, C3) instead — no hardware needed; install it once
    with `idf_tools.py install qemu-xtensa`.
- Open a file from the command line (`ESPIDE path/to/file.md`): its git repository (or folder) opens as the project.
- From PyIDE: tabs, Python highlighting and editing, pyright completion / hover / go to definition / references / rename, Outline, ruff formatting.

## Develop

```sh
swift test                                              # unit tests (fake board)
ESPIDE_TEST_PORT=/dev/cu.usbserial-110 swift test       # plus a round trip against a real board
ESPIDE_IDF_SETUP=~/esp/esp-idf/export.sh ESPIDE_IDF_PROJECT=/tmp/hello_world swift test   # real idf.py build
ESPIDE_IDF_SETUP=~/esp/esp-idf/export.sh ESPIDE_QEMU_PROJECT=/tmp/hello_world swift test   # GDB/DAP against QEMU
ESPIDE_INSTRUMENT_DIR=~/path/to/micropython/project swift test   # its files still compile once instrumented
ESPIDE_TRACE_DAP=1 swift run ESPIDE …                   # log debug adapter traffic
swift run ESPIDE ~/path/to/micropython/project
scripts/bundle.sh                                       # build/ESPIDE.app (ad-hoc signed)
swift scripts/make-icon.swift                           # regenerate Resources/AppIcon.icns
```

Layout:

- `Sources/ESPIDECore` — UI-independent: `SerialPort` (termios), `MicroPythonDevice` (raw REPL), `DeviceFiles` (list/read/write/hash/delete),
  `ProjectSync`, `PythonInstrumenter` + `MicroPythonDebugger` (the MicroPython debugger), `IDFDebug`, `DAPClient`, `Firmware` (esptool commands, micropython.org images), `PlotParser`/`PlotData`, `I2C`, `MicroPythonStubs`, `Mip`, `PinScanner`, `Markdown`, `IDFProject`, `CHighlighter`, `Clangd`,
  plus PyIDE's LSP client and text utilities.
- `Sources/ESPIDE` — the app: `Board` (connection, REPL, run, files), `Workspace`, editor and views.

Requires macOS 14+. MicroPython features need a board flashed with MicroPython (or use *Flash MicroPython Firmware…*);
ESP-IDF features need an ESP-IDF install.

## Roadmap

- Testing ESP-IDF debugging on real USB-JTAG hardware (so far: GDB/DAP verified against QEMU)
