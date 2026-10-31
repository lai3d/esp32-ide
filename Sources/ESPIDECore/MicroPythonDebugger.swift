import Foundation

/// The board-side half of the MicroPython debugger: `_K`/`_P` called by the probes that
/// `PythonInstrumenter` adds. Runs on MicroPython and CPython (the tests use CPython).
///
/// Board → IDE: lines starting with \x1e carrying JSON (`stop`, `eval`), in the program's stdout.
/// IDE → board: command lines on stdin — `c` continue, `s` step, `n` step over, `o` step out,
/// `e <json string>` evaluate, `b <json [[line, condition]…]>` breakpoints, `p` pause.
/// While running, stdin is polled every 8 probes, so `p` and `b` take effect at the next statement.
enum DebugRuntime {
    static func script(_ result: PythonInstrumenter.Result, breakpoints: [Int: String?]) -> String {
        let functions = result.functionOf.sorted { $0.key < $1.key }.map { "\($0.key):\(literal($0.value))" }.joined(separator: ",")
        let names = result.localNames.sorted { $0.key < $1.key }
            .map { "\(literal($0.key)):(\($0.value.map(literal).joined(separator: ","))\($0.value.count == 1 ? "," : ""))" }
            .joined(separator: ",")
        let exits = result.exitLines.isEmpty ? "set()" : "{" + result.exitLines.sorted().map(String.init).joined(separator: ",") + "}"
        return """
        import sys
        try:
            import json
        except ImportError:
            import ujson as json
        _DB = \(breakpointLiteral(breakpoints))
        _DF = {\(functions)}
        _DN = {\(names)}
        _DR = \(exits)
        _DS = [0, '', 0, 0, '']
        try:
            import select
            _DQ = select.poll()
            _DQ.register(sys.stdin, select.POLLIN)
        except Exception:
            _DQ = None

        def _K(n):
            m = _DS[0]
            if m == 0:
                _DS[3] += 1
                if _DQ and not _DS[3] & 7 and _DQ.poll(0):
                    _Dc(_Dl())
                    m = _DS[0]
                if m == 0:
                    if n in _DB:
                        _DS[4] = 'breakpoint'
                        return 1
                    return 0
            if m == 1 or m == 4:
                _DS[4] = 'pause' if m == 4 else 'step'
                return 1
            if n in _DB:
                _DS[4] = 'breakpoint'
                return 1
            f = _DF.get(n, '')
            if (m == 2 and (f == _DS[1] or _DS[2])) or (m == 3 and _DS[2] and f != _DS[1]):
                _DS[4] = 'step'
                return 1
            if f == _DS[1] and n in _DR:
                _DS[2] = 1
            return 0

        def _P(n, *a):
            f = _DF.get(n, '')
            L = {}
            for i, k in enumerate(_DN.get(f, ())):
                try:
                    L[k] = a[i]()
                except Exception:
                    pass
            r = _DS[4]
            if r == 'breakpoint' and _DB.get(n):
                try:
                    if not eval(_DB[n], globals(), L):
                        return
                except Exception:
                    pass
            _DS[0] = 0
            _DS[2] = 0
            _Dw({'t': 'stop', 'l': n, 'f': f, 'r': r, 'v': _Dv(L, 0), 'g': _Dv(globals(), 1)})
            while True:
                c = _Dl()
                k = c[0]
                if k == 'e':
                    try:
                        _Dw({'t': 'eval', 'ok': 1, 'v': _Dr(eval(json.loads(c[2:]), globals(), L))})
                    except Exception as x:
                        _Dw({'t': 'eval', 'ok': 0, 'v': '%s: %s' % (type(x).__name__, x)})
                elif k == 'b':
                    _Dc(c)
                elif k in 'csno':
                    _DS[0] = 'csno'.index(k)
                    _DS[1] = f
                    _DS[2] = 1 if n in _DR and k in 'no' else 0
                    return

        def _Dc(c):
            if c[0] == 'p':
                _DS[0] = 4
            elif c[0] == 'b':
                _DB.clear()
                for k, v in json.loads(c[2:]):
                    _DB[k] = v

        def _Dl():
            s = ''
            while True:
                ch = sys.stdin.read(1)
                if not ch:
                    raise KeyboardInterrupt
                if ch == '\\r' or ch == '\\n':
                    if s:
                        return s
                else:
                    s += ch

        def _Dr(v):
            try:
                r = repr(v)
            except Exception:
                r = '<?>'
            return r if len(r) <= 200 else r[:197] + '...'

        def _Dv(d, g):
            o = []
            for k in sorted(d):
                if k[0] == '_':
                    continue
                v = d[k]
                if g and (callable(v) or type(v) is type(sys)):
                    continue
                o.append([k, _Dr(v), type(v).__name__])
                if len(o) >= 200:
                    break
            return o

        def _Dw(d):
            print('\\x1e' + json.dumps(d))

        """
    }

    /// A Python string literal (ASCII only, so it survives the serial link byte by byte).
    static func literal(_ text: String) -> String {
        "'" + ascii(text).replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Escapes everything outside printable ASCII as \uXXXX (valid in both JSON and Python strings).
    static func ascii(_ text: String) -> String {
        var out = ""
        for unit in text.utf16 {
            switch unit {
            case 0x5C: out += "\\\\"
            case 0x20..<0x7F: out.append(Character(Unicode.Scalar(unit)!))
            default: out += String(format: "\\u%04x", unit)
            }
        }
        return out
    }

    /// `[[12, None], [15, 'i == 3']]` for the initial `_DB` dict.
    static func breakpointLiteral(_ breakpoints: [Int: String?]) -> String {
        "{" + breakpoints.sorted { $0.key < $1.key }.map { line, condition in
            "\(line): " + (condition.map(literal) ?? "None")
        }.joined(separator: ", ") + "}"
    }

    /// The `b` command: `b [[12,null],[15,"i == 3"]]`.
    static func breakpointCommand(_ breakpoints: [Int: String?]) -> String {
        "b [" + breakpoints.sorted { $0.key < $1.key }.map { line, condition in
            "[\(line),\(condition.map { "\"" + ascii($0).replacingOccurrences(of: "\"", with: "\\\"") + "\"" } ?? "null")]"
        }.joined(separator: ",") + "]"
    }

    /// The `e` command: the expression as a JSON string.
    static func evaluateCommand(_ expression: String) -> String {
        "e \"" + ascii(expression).replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Splits program output into plain text and the debugger's \x1e-prefixed JSON messages.
struct DebugOutputParser {
    private var pending = ""

    enum Piece: Equatable {
        case text(String)
        case message(JSONValue)
    }

    mutating func feed(_ chunk: String) -> [Piece] {
        pending += chunk
        var pieces: [Piece] = []
        while !pending.isEmpty {
            guard let marker = pending.firstIndex(of: "\u{1E}") else {
                pieces.append(.text(pending))
                pending = ""
                break
            }
            if marker > pending.startIndex { pieces.append(.text(String(pending[..<marker]))) }
            // Wait for the whole message line (MicroPython prints \r\n through the raw REPL).
            guard let end = pending[marker...].firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) else {
                pending = String(pending[marker...])
                break
            }
            let json = pending[pending.index(after: marker)..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) { pieces.append(.message(value)) }
            pending = String(pending[pending.index(after: end)...])
        }
        return pieces
    }
}

/// An in-process debug adapter for MicroPython: answers the Debug panel's DAP requests by
/// running the instrumented program on the board and talking to `DebugRuntime` over the serial line.
public final class MicroPythonDebugAdapter: DebugAdapter, @unchecked Sendable {
    public typealias Runner = @Sendable (_ runtime: String, _ program: String, _ onOutput: @escaping @Sendable (String) -> Void) async throws -> Void

    private let lock = NSLock()
    private let path: String
    private let instrumented: PythonInstrumenter.Result
    private let run: Runner
    private let write: @Sendable (String) -> Void
    private let interrupt: @Sendable () -> Void
    private var _onEvent: DAPClient.EventHandler?
    private var _onExit: DAPClient.ExitHandler?
    private var breakpoints: [Int: String?] = [:]
    private var parser = DebugOutputParser()
    private var stop: JSONValue?
    private var evaluations: [CheckedContinuation<JSONValue, Never>] = []
    private var started = false
    private var finished = false
    private var runTask: Task<Void, Never>?

    /// - Parameters:
    ///   - run: executes the runtime then the program in one fresh interpreter, streaming stdout.
    ///   - write: sends text to the program's stdin.
    ///   - interrupt: Ctrl-C.
    public init(path: String, source: String, run: @escaping Runner,
                write: @escaping @Sendable (String) -> Void, interrupt: @escaping @Sendable () -> Void) {
        self.path = path
        self.instrumented = PythonInstrumenter.instrument(source)
        self.run = run
        self.write = write
        self.interrupt = interrupt
    }

    public var onEvent: DAPClient.EventHandler? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    public var onExit: DAPClient.ExitHandler? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    /// Sends a line to the running program's `input()`.
    public func sendInput(_ line: String) {
        write(line + "\r")
    }

    public func terminate() {
        let task = lock.withLock { runTask }
        if task != nil, !lock.withLock({ finished }) { interrupt() }
    }

    public func request(_ command: String, arguments: JSONValue) async throws -> JSONValue {
        switch command {
        case "initialize":
            Task {
                try? await Task.sleep(for: .milliseconds(10))
                self.emit("initialized")
            }
            return ["supportsConfigurationDoneRequest": true, "supportsConditionalBreakpoints": true]
        case "launch", "setExceptionBreakpoints":
            return [:]
        case "setBreakpoints":
            return setBreakpoints(arguments)
        case "configurationDone":
            start()
            return [:]
        case "threads":
            return ["threads": [["id": 1, "name": "main"]]]
        case "continue", "next", "stepIn", "stepOut":
            let letter = ["continue": "c", "next": "n", "stepIn": "s", "stepOut": "o"][command]!
            guard lock.withLock({ () -> Bool in
                guard stop != nil else { return false }
                stop = nil
                return true
            }) else { throw DAPClient.ClientError.failed(command: command, message: "not paused") }
            write(letter + "\n")
            emit("continued", ["threadId": 1])
            return [:]
        case "pause":
            write("p\n")
            return [:]
        case "stackTrace":
            guard let stop = lock.withLock({ stop }) else { return ["stackFrames": []] }
            let function = stop["f"]?.stringValue ?? ""
            return ["stackFrames": [[
                "id": 1, "name": .string(function.isEmpty ? "<module>" : function),
                "source": ["path": .string(path)], "line": stop["l"] ?? 0, "column": 1,
            ]]]
        case "scopes":
            guard let stop = lock.withLock({ stop }) else { return ["scopes": []] }
            var scopes: [JSONValue] = []
            if !(stop["f"]?.stringValue ?? "").isEmpty { scopes.append(["name": "Locals", "variablesReference": 1]) }
            scopes.append(["name": "Globals", "variablesReference": 2])
            return ["scopes": .array(scopes)]
        case "variables":
            guard let stop = lock.withLock({ stop }) else { return ["variables": []] }
            let key = arguments["variablesReference"]?.intValue == 1 ? "v" : "g"
            let variables = (stop[key]?.arrayValue ?? []).compactMap { item -> JSONValue? in
                guard let triple = item.arrayValue, triple.count == 3 else { return nil }
                return ["name": triple[0], "value": triple[1], "type": triple[2], "variablesReference": 0]
            }
            return ["variables": .array(variables)]
        case "evaluate":
            let expression = arguments["expression"]?.stringValue ?? ""
            let reply = try await evaluate(expression)
            guard reply["ok"]?.intValue == 1 else {
                throw DAPClient.ClientError.failed(command: "evaluate", message: reply["v"]?.stringValue ?? "error")
            }
            return ["result": reply["v"] ?? "", "variablesReference": 0]
        case "setVariable":
            throw DAPClient.ClientError.failed(command: command, message: "MicroPython variables can't be changed from the debugger")
        case "disconnect":
            terminate()
            return [:]
        default:
            throw DAPClient.ClientError.failed(command: command, message: "not supported")
        }
    }

    // MARK: - Private

    private func setBreakpoints(_ arguments: JSONValue) -> JSONValue {
        let requested = arguments["breakpoints"]?.arrayValue ?? []
        guard arguments["source"]?["path"]?.stringValue == path else {
            return ["breakpoints": .array(requested.map { _ in ["verified": false, "message": "Only the file being debugged can stop"] })]
        }
        var lines: [Int: String?] = [:]
        var replies: [JSONValue] = []
        for item in requested {
            guard let line = item["line"]?.intValue, let probe = instrumented.probeLine(atOrAfter: line) else {
                replies.append(["verified": false, "message": "No code at or after this line"])
                continue
            }
            let condition = item["condition"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            lines[probe] = condition
            replies.append(["verified": true, "line": .int(probe)])
        }
        let isRunning = lock.withLock {
            breakpoints = lines
            return started && !finished
        }
        if isRunning { write(DebugRuntime.breakpointCommand(lines) + "\n") }
        return ["breakpoints": .array(replies)]
    }

    private func start() {
        let (runtime, program): (String, String) = lock.withLock {
            started = true
            return (DebugRuntime.script(instrumented, breakpoints: breakpoints), instrumented.code)
        }
        let task = Task { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            do {
                try await self.run(runtime, program) { [weak self] text in self?.received(text) }
            } catch let error as DeviceError {
                status = 1
                if case let .exception(traceback) = error {
                    let name = (self.path as NSString).lastPathComponent
                    let text = TerminalText.cleaned(traceback).replacingOccurrences(of: "\"<stdin>\"", with: "\"\(name)\"")
                    self.emit("output", ["category": "stderr", "output": .string(text)])
                    if traceback.contains("KeyboardInterrupt") { status = 130 }
                } else {
                    self.emit("output", ["category": "stderr", "output": .string(error.localizedDescription + "\n")])
                }
            } catch {
                status = 1
                self.emit("output", ["category": "stderr", "output": .string(error.localizedDescription + "\n")])
            }
            self.finish(status)
        }
        lock.withLock { runTask = task }
    }

    private func finish(_ status: Int32) {
        let (waiters, exit) = lock.withLock {
            finished = true
            stop = nil
            let waiters = evaluations
            evaluations = []
            return (waiters, _onExit)
        }
        for waiter in waiters { waiter.resume(returning: ["ok": 0, "v": "the program ended"]) }
        emit("exited", ["exitCode": .int(Int(status))])
        emit("terminated")
        exit?(status == 130 ? 0 : status)
    }

    private func received(_ text: String) {
        let pieces = lock.withLock { parser.feed(text) }
        for piece in pieces {
            switch piece {
            case let .text(output):
                emit("output", ["category": "stdout", "output": .string(TerminalText.cleaned(output))])
            case let .message(message):
                switch message["t"]?.stringValue {
                case "stop":
                    lock.withLock { stop = message }
                    let reason = message["r"]?.stringValue ?? "step"
                    let line = message["l"]?.intValue ?? 0
                    emit("stopped", ["reason": .string(reason), "threadId": 1, "allThreadsStopped": true,
                                     "description": .string(Self.describe(reason, line: line))])
                case "eval":
                    let waiter = lock.withLock { evaluations.isEmpty ? nil : evaluations.removeFirst() }
                    waiter?.resume(returning: message)
                default:
                    break
                }
            }
        }
    }

    private static func describe(_ reason: String, line: Int) -> String {
        switch reason {
        case "breakpoint": "Paused on breakpoint, line \(line)"
        case "pause": "Paused at line \(line)"
        default: "Paused at line \(line)"
        }
    }

    /// Evaluations are answered in order, so they're queued; only possible while paused.
    private func evaluate(_ expression: String) async throws -> JSONValue {
        guard lock.withLock({ stop != nil }) else {
            throw DAPClient.ClientError.failed(command: "evaluate", message: "pause the program first")
        }
        return await withCheckedContinuation { continuation in
            lock.withLock { evaluations.append(continuation) }
            write(DebugRuntime.evaluateCommand(expression) + "\n")
        }
    }

    private func emit(_ event: String, _ body: JSONValue = .null) {
        onEvent?(event, body)
    }
}
