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
  UART0, one pin used as two different things. Rules for ESP32, ESP32-S3 and ESP32-C3, picked from the connected board
  (`sys.implementation._machine`) or chosen in the sidebar. Click a use to jump to it.
- **Upload** (⌘U) the current file to the same path on the board; **Sync** (⇧⌘S) uploads every changed `.py`/`.json` file of the project.
  Unchanged files are skipped by comparing SHA-256 on the Mac and on the board. `docs/`, `tests/`, hidden folders and `*.example.py` are not uploaded.
- **MicroPython completion**: *Python → Install MicroPython Stubs* puts `micropython-esp32-stubs` into
  `~/Library/Application Support/ESPIDE/stubs` (your project is not modified) and points pyright at them, so `machine`, `network`, `neopixel`, …
  complete and type-check against MicroPython's own standard library. Without stubs, unresolved imports are silenced.
- **Flash firmware** (*Board → Flash MicroPython Firmware…*): detect the chip with esptool, download the latest stable image from
  micropython.org (or pick a `.bin`), optionally erase, write at the right offset (0x1000 for ESP32, 0x0 for S2/S3/C3/C6) with a progress bar,
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
- Open a file from the command line (`ESPIDE path/to/file.md`): its git repository (or folder) opens as the project.
- From PyIDE: tabs, Python highlighting and editing, pyright completion / hover / go to definition / references / rename, Outline, ruff formatting.

## Develop

```sh
swift test                                              # unit tests (fake board)
ESPIDE_TEST_PORT=/dev/cu.usbserial-110 swift test       # plus a round trip against a real board
ESPIDE_IDF_SETUP=~/esp/esp-idf/export.sh ESPIDE_IDF_PROJECT=/tmp/hello_world swift test   # real idf.py build
swift run ESPIDE ~/path/to/micropython/project
scripts/bundle.sh                                       # build/ESPIDE.app (ad-hoc signed)
swift scripts/make-icon.swift                           # regenerate Resources/AppIcon.icns
```

Layout:

- `Sources/ESPIDECore` — UI-independent: `SerialPort` (termios), `MicroPythonDevice` (raw REPL), `DeviceFiles` (list/read/write/hash/delete),
  `ProjectSync`, `Firmware` (esptool commands, micropython.org images), `PlotParser`/`PlotData`, `I2C`, `MicroPythonStubs`, `Mip`, `PinScanner`, `Markdown`, `IDFProject`, `CHighlighter`, `Clangd`,
  plus PyIDE's LSP client and text utilities.
- `Sources/ESPIDE` — the app: `Board` (connection, REPL, run, files), `Workspace`, editor and views.

Requires macOS 14+. MicroPython features need a board flashed with MicroPython (or use *Flash MicroPython Firmware…*);
ESP-IDF features need an ESP-IDF install.

## Roadmap

- Pin rules for more chips (C6, P4)
- Debugging ESP-IDF apps with OpenOCD + GDB
