import Foundation
import Observation
import ESPIDECore

/// One debug session — MicroPython on the board, or GDB for ESP-IDF: drives the debug adapter and
/// holds the state the Debug panel shows.
@MainActor
@Observable
final class DebugSession {
    enum State: Equatable {
        case starting, running, stopped, ended
    }

    private(set) var state: State = .starting
    private(set) var stopDescription = ""
    private(set) var frames: [StackFrameInfo] = []
    private(set) var selectedFrameID: Int?
    private(set) var scopes: [VariableInfo] = []
    /// Bumped on every stop so variable trees (whose references are only valid per stop) rebuild.
    private(set) var stopCount = 0
    private(set) var console = ""
    /// Watch expression → its value in the selected frame (or the error message).
    private(set) var watchValues: [String: String] = [:]
    private(set) var watchExpressions: [String] = []

    @ObservationIgnored private let client: DebugAdapter
    @ObservationIgnored private var afterConfiguration: (@MainActor (DebugSession) async -> Void)?
    @ObservationIgnored private var threadID: Int?
    @ObservationIgnored private var exceptionFilters: Set<String> = []
    /// Bumped on every stop and resume, so late replies for an earlier stop are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var breakpoints: [String: [SourceBreakpoint]]
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    /// Where console input goes while the program runs (MicroPython's `input()`); nil if nowhere.
    @ObservationIgnored var sendInput: ((String) -> Void)?
    /// Called when the session ends, e.g. to stop OpenOCD.
    @ObservationIgnored var onCleanup: () -> Void = {}

    /// Called when execution stops at a location (path, 1-based line), or with nil when it resumes.
    @ObservationIgnored var onLocation: ((String, Int)?) -> Void = { _ in }
    @ObservationIgnored var onEnd: () -> Void = {}

    let programName: String

    init(adapter: DebugAdapter, breakpoints: [String: [SourceBreakpoint]], programName: String) {
        self.client = adapter
        self.breakpoints = breakpoints
        self.programName = programName
    }

    var isStopped: Bool { state == .stopped }
    var isActive: Bool { state != .ended }

    // MARK: Lifecycle

    var adapter: DebugAdapter { client }

    /// Initializes the adapter, then `launch` sends `launch` or `attach` with the adapter's arguments;
    /// `afterConfiguration` runs once breakpoints are set (e.g. to reset the chip and continue).
    func start(launch: @escaping @MainActor (DebugAdapter) async throws -> Void,
               afterConfiguration: (@MainActor (DebugSession) async -> Void)? = nil) {
        self.afterConfiguration = afterConfiguration
        client.onEvent = { [weak self] event, body in
            Task { @MainActor in self?.handle(event: event, body: body) }
        }
        client.onExit = { [weak self] status in
            Task { @MainActor in
                guard let self, self.state != .ended else { return }
                if status != 0, let process = self.client as? DAPClient {
                    let stderr = process.stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.log("\n[debugger exited with status \(status)]\(stderr.isEmpty ? "" : "\n" + stderr)\n")
                }
                self.end()
            }
        }
        launchTask = Task {
            do {
                let capabilities = try await client.request("initialize", arguments: [
                    "clientID": "espide", "clientName": "ESPIDE", "adapterID": "espide",
                    "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
                    "supportsVariableType": true,
                ])
                exceptionFilters = Set((capabilities["exceptionBreakpointFilters"]?.arrayValue ?? []).compactMap { $0["filter"]?.stringValue })
                try await launch(client)
                if state == .starting { state = .running }
            } catch {
                log("Launch failed: \(error.localizedDescription)\n")
                stop()
            }
        }
    }

    func log(_ text: String) {
        console += text
        if console.utf16.count > 400_000 { console = String(console.suffix(300_000)) }
    }

    func stop() {
        guard state != .ended else { return }
        Task {
            _ = try? await client.request("disconnect", arguments: ["terminateDebuggee": true])
            try? await Task.sleep(for: .milliseconds(300))
            client.terminate()
        }
        end()
    }

    private func end() {
        guard state != .ended else { return }
        state = .ended
        onCleanup()
        frames = []
        scopes = []
        onLocation(nil)
        log("\n[debug session ended]\n")
        onEnd()
    }

    // MARK: Breakpoints

    func setBreakpoints(path: String, _ list: [SourceBreakpoint]) {
        breakpoints[path] = list
        guard state != .starting, state != .ended else { return }
        client.send("setBreakpoints", arguments: Self.breakpointArguments(path: path, list))
    }

    private static func breakpointArguments(path: String, _ list: [SourceBreakpoint]) -> JSONValue {
        ["source": ["path": .string(path)], "breakpoints": .array(list.sorted { $0.line < $1.line }.map(\.json))]
    }

    private func sendConfiguration() async {
        for (path, list) in breakpoints {
            _ = try? await client.request("setBreakpoints", arguments: Self.breakpointArguments(path: path, list))
        }
        // debugpy's "uncaught"; GDB only knows Ada/C++ ones, which ESP-IDF apps don't need.
        if exceptionFilters.contains("uncaught") {
            _ = try? await client.request("setExceptionBreakpoints", arguments: ["filters": ["uncaught"]])
        }
        _ = try? await client.request("configurationDone")
        if let afterConfiguration {
            self.afterConfiguration = nil
            await afterConfiguration(self)
        }
    }

    // MARK: Execution control

    func resume() { control("continue") }
    func stepOver() { control("next") }
    func stepIn() { control("stepIn") }
    func stepOut() { control("stepOut") }

    /// Waits (up to `timeout`) for the program to stop, e.g. GDB's stop after attaching.
    func waitUntilStopped(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while state != .stopped && state != .ended && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return state == .stopped
    }

    func pause() {
        guard state == .running else { return }
        client.send("pause", arguments: ["threadId": .int(threadID ?? 1)])
    }

    private func control(_ command: String) {
        guard state == .stopped, let threadID else { return }
        state = .running
        generation += 1
        watchValues = [:]
        frames = []
        scopes = []
        onLocation(nil)
        client.send(command, arguments: ["threadId": .int(threadID)])
    }

    // MARK: Program input

    /// Console input: evaluates while paused, otherwise goes to the program's stdin.
    func submitConsoleInput(_ line: String) {
        if state == .stopped {
            evaluate(line)
        } else if state == .running, let sendInput {
            log(line + "\n")
            sendInput(line)
        }
    }

    var acceptsInput: Bool { sendInput != nil }

    // MARK: Inspection

    func setWatches(_ expressions: [String]) {
        watchExpressions = expressions
        refreshWatches()
    }

    /// Evaluates every watch expression in the selected frame.
    func refreshWatches() {
        guard state == .stopped, let frameID = selectedFrameID else {
            watchValues = [:]
            return
        }
        for expression in watchExpressions {
            Task {
                let value: String
                do {
                    let body = try await client.request("evaluate", arguments: [
                        "expression": .string(expression), "frameId": .int(frameID), "context": "watch",
                    ])
                    value = body["result"]?.stringValue ?? ""
                } catch {
                    value = "⚠︎ " + (error.localizedDescription.components(separatedBy: "failed: ").last ?? "error")
                }
                guard selectedFrameID == frameID else { return }
                watchValues[expression] = value
            }
        }
    }

    func select(frame: StackFrameInfo) {
        selectedFrameID = frame.id
        if let path = frame.path { onLocation((path, frame.line)) }
        refreshWatches()
        Task {
            let body = try? await client.request("scopes", arguments: ["frameId": .int(frame.id)])
            guard selectedFrameID == frame.id else { return }
            scopes = body.map(VariableInfo.parseAll) ?? []
            stopCount += 1
        }
    }

    func children(of reference: Int) async -> [VariableInfo] {
        guard reference > 0, state == .stopped,
              let body = try? await client.request("variables", arguments: ["variablesReference": .int(reference)])
        else { return [] }
        return VariableInfo.parseAll(body)
    }

    /// Assigns `value` (a Python expression) to a variable, then refreshes variables and watches.
    func setVariable(_ name: String, in container: Int, to value: String) async -> String? {
        guard state == .stopped else { return "Pause first" }
        do {
            _ = try await client.request("setVariable", arguments: [
                "variablesReference": .int(container), "name": .string(name), "value": .string(value),
            ])
        } catch {
            return error.localizedDescription.components(separatedBy: "failed: ").last
        }
        if let frame = frames.first(where: { $0.id == selectedFrameID }) { select(frame: frame) }
        return nil
    }

    /// Evaluates an expression in the selected frame (or globally while running) and logs the result.
    func evaluate(_ expression: String) {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, state != .ended else { return }
        log(">>> \(trimmed)\n")
        var arguments: [String: JSONValue] = ["expression": .string(trimmed), "context": "repl"]
        if let selectedFrameID { arguments["frameId"] = .int(selectedFrameID) }
        Task {
            do {
                let body = try await client.request("evaluate", arguments: .object(arguments))
                log((body["result"]?.stringValue ?? "") + "\n")
            } catch {
                log("\(error.localizedDescription)\n")
            }
        }
    }

    // MARK: Events

    private func handle(event: String, body: JSONValue) {
        guard state != .ended else { return }
        switch event {
        case "initialized":
            Task { await sendConfiguration() }
        case "stopped":
            generation += 1
            threadID = body["threadId"]?.intValue ?? threadID
            state = .stopped
            let reason = body["reason"]?.stringValue ?? "pause"
            stopDescription = body["description"]?.stringValue ?? "Paused on \(reason)"
            Task { await loadStack(reason: reason) }
        case "continued":
            if state == .stopped {
                state = .running
                frames = []
                scopes = []
                onLocation(nil)
            }
        case "output":
            let category = body["category"]?.stringValue ?? "console"
            guard category != "telemetry", let text = body["output"]?.stringValue else { return }
            log(text)
        case "terminated", "exited":
            if event == "exited", let code = body["exitCode"]?.intValue { log("\n[process exited with status \(code)]\n") }
            if event == "terminated" { stop() }
        default:
            break
        }
    }

    private func loadStack(reason: String) async {
        let stop = generation
        guard let threadID,
              let body = try? await client.request("stackTrace", arguments: ["threadId": .int(threadID), "levels": 50]),
              state == .stopped, stop == generation  // not resumed (or stopped again) meanwhile
        else { return }
        frames = StackFrameInfo.parseAll(body)
        if reason == "exception",
           let info = try? await client.request("exceptionInfo", arguments: ["threadId": .int(threadID)]) {
            let id = info["exceptionId"]?.stringValue ?? "Exception"
            let description = info["description"]?.stringValue ?? ""
            stopDescription = "\(id): \(description)"
            log("\n\(stopDescription)\n")
        }
        if let top = frames.first(where: { $0.path != nil }) ?? frames.first { select(frame: top) }
    }
}
