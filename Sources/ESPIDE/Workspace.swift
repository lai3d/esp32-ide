import AppKit
import ESPIDECore
import Observation

enum BottomTab: Hashable {
    case problems, output, references, repl, plot
}

/// One result of Find References, with its source line for context.
struct ReferenceItem: Identifiable {
    let id = UUID()
    let url: URL
    let position: TextPosition
    let lineText: String
    var fileName: String { url.lastPathComponent }
}

/// A request for the editor to move the caret to a position.
struct RevealTarget: Equatable {
    let id = UUID()
    let position: TextPosition
}

struct NavigationPoint: Equatable {
    let url: URL
    let position: TextPosition
}

struct ProblemItem: Identifiable {
    let path: String
    let diagnostic: Diagnostic
    var id: UUID { diagnostic.id }
    var fileName: String { (path as NSString).lastPathComponent }
}

/// A file open in an editor tab.
struct OpenDocument: Identifiable {
    let url: URL
    var text: String
    var isDirty = false
    var version = 1
    /// Normalized path; the identity used for tabs, diagnostics and editor state.
    var id: String { Workspace.key(for: url) }
    var name: String { url.lastPathComponent }
}

/// All state for one open project folder: files, editor buffer, the language server, and python processes.
@MainActor
@Observable
final class Workspace {
    private(set) var rootURL: URL?
    private(set) var fileTree: [FileNode] = []
    private(set) var documents: [OpenDocument] = []
    private(set) var currentFile: URL? {
        didSet { if oldValue != currentFile { scheduleOutlineRefresh(after: .zero) } }
    }
    /// Symbols of the current file for the Outline sidebar.
    private(set) var outline: [OutlineSymbol] = []
    @ObservationIgnored private var outlineTask: Task<Void, Never>?
    @ObservationIgnored private var fileWatcher: FileWatcher?
    private(set) var diagnostics: [String: [Diagnostic]] = [:]  // keyed by normalized path
    private(set) var lspStatus = "Language server: not started"
    private(set) var interpreter: URL?
    /// The connected board (serial port, REPL, files).
    let board = Board()
    var bottomTab: BottomTab = .problems
    /// Run ruff/black on ⌘S. Persisted across launches.
    var formatOnSave: Bool = UserDefaults.standard.object(forKey: "formatOnSave") as? Bool ?? true {
        didSet { UserDefaults.standard.set(formatOnSave, forKey: "formatOnSave") }
    }
    var revealTarget: RevealTarget?
    private(set) var backStack: [NavigationPoint] = []
    private(set) var references: [ReferenceItem] = []
    private(set) var referencesQuery = ""
    /// UTF-16 caret offset in the current file, reported by the editor.
    @ObservationIgnored var caretOffset = 0
    /// Current editor selection (UTF-16), reported by the editor.
    @ObservationIgnored var selectedRange = NSRange(location: 0, length: 0)

    @ObservationIgnored private var lsp: LSPClient?
    @ObservationIgnored private var lspName = "Language server"
    @ObservationIgnored private var lspReady = false
    @ObservationIgnored private var handledLaunchArguments = false

    init() {
        board.onStatus = { [weak self] in self?.flashStatus($0) }
        board.onShowPanel = { [weak self] in self?.bottomTab = $0 }
    }

    var currentDiagnostics: [Diagnostic] {
        guard let currentFile else { return [] }
        return diagnostics[Self.key(for: currentFile)] ?? []
    }

    var allProblems: [ProblemItem] {
        diagnostics.keys.sorted().flatMap { path in
            diagnostics[path, default: []].map { ProblemItem(path: path, diagnostic: $0) }
        }
    }

    private var currentIndex: Int? {
        guard let currentFile else { return nil }
        let key = Self.key(for: currentFile)
        return documents.firstIndex { $0.id == key }
    }

    var text: String { currentIndex.map { documents[$0].text } ?? "" }
    var currentVersion: Int { currentIndex.map { documents[$0].version } ?? 0 }
    var isDirty: Bool { currentIndex.map { documents[$0].isDirty } ?? false }
    var hasUnsavedChanges: Bool { documents.contains { $0.isDirty } }
    var currentDocumentID: String { currentFile.map(Self.key(for:)) ?? "" }

    var isPythonFile: Bool { currentFile.map(Self.isPython) ?? false }

    /// Files outside the project (stdlib, typeshed stubs) or inside a virtualenv are opened read-only.
    var isReadOnly: Bool { currentFile.map(isReadOnly) ?? false }

    func isReadOnly(_ url: URL) -> Bool {
        if Self.boardPath(ofCached: url) != nil { return false }  // edited copies of board files
        guard let rootURL else { return false }
        let path = Self.key(for: url)
        let root = Self.key(for: rootURL)
        guard path.hasPrefix(root + "/") else { return true }
        let relative = path.dropFirst(root.count + 1)
        return relative.contains("/site-packages/")
            || PythonEnvironment.venvNames.contains { relative.hasPrefix($0 + "/") }
    }

    var canGoBack: Bool { !backStack.isEmpty }

    var interpreterLabel: String {
        guard let interpreter else { return "No Python" }
        if let venv = PythonEnvironment.virtualEnvRoot(of: interpreter) { return "Python (\(venv.lastPathComponent))" }
        return interpreter.path
    }

    // MARK: - Folder

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Python project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openFolder(url) }
    }

    /// Opens a folder passed on the command line, e.g. `swift run ESPIDE ./Examples/hello`.
    func handleLaunchArguments() async {
        guard !handledLaunchArguments else { return }
        handledLaunchArguments = true
        for arg in CommandLine.arguments.dropFirst() {
            var isDir: ObjCBool = false
            let url = URL(fileURLWithPath: arg).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                await openFolder(url)
                return
            }
        }
    }

    func openFolder(_ url: URL) async {
        guard confirmDiscardOrSave(documents.filter(\.isDirty)) else { return }
        await stopLanguageServer()
        rootURL = url
        fileTree = FileNode.loadTree(at: url)
        fileWatcher = FileWatcher(url: url, ignoredComponents: FileNode.ignoredNames.union([".git"])) { [weak self] in
            self?.reloadTree()
        }
        interpreter = PythonEnvironment.interpreter(for: url)
        currentFile = nil
        documents = []
        diagnostics = [:]
        backStack = []
        let preferred = ["main.py", "__main__.py", "app.py"].lazy.compactMap { Self.firstFile(named: $0, in: self.fileTree) }.first
        if let first = preferred ?? Self.firstPythonFile(in: fileTree) {
            openFile(first)
        }
        await startLanguageServer(root: url)
    }

    func reloadTree() {
        guard let rootURL else { return }
        fileTree = FileNode.loadTree(at: rootURL)
    }

    func presentInterpreterPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true  // .venv
        panel.treatsFilePackagesAsDirectories = true
        panel.resolvesAliases = false  // keep .venv/bin/python, not the base interpreter it links to
        panel.prompt = "Use Interpreter"
        panel.message = "Choose a Python interpreter (e.g. .venv/bin/python)"
        panel.directoryURL = interpreter?.deletingLastPathComponent() ?? rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            flashStatus("\(url.lastPathComponent) is not executable")
            return
        }
        interpreter = url
        Task { await restartLanguageServer() }
    }

    // MARK: - Files

    /// Opens `url` in a tab (or switches to its existing tab).
    func openFile(_ url: URL) {
        let key = Self.key(for: url)
        if documents.contains(where: { $0.id == key }) {
            currentFile = url
            return
        }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            flashStatus("Cannot open \(url.lastPathComponent) (not UTF-8 text?)")
            return
        }
        let document = OpenDocument(url: url, text: contents)
        let insertAt = currentIndex.map { $0 + 1 } ?? documents.count
        documents.insert(document, at: insertAt)
        currentFile = url
        caretOffset = 0
        sendDidOpen(document)
    }

    func selectTab(_ document: OpenDocument) {
        currentFile = document.url
    }

    func selectAdjacentTab(_ delta: Int) {
        guard let index = currentIndex, documents.count > 1 else { return }
        let next = (index + delta + documents.count) % documents.count
        currentFile = documents[next].url
    }

    /// Closes a tab, asking to save it first if it has unsaved changes.
    func close(_ document: OpenDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        guard confirmDiscardOrSave([documents[index]]) else { return }
        let closing = documents.remove(at: index)
        sendDidClose(closing)
        diagnostics.removeValue(forKey: closing.id)  // re-published if the file is reopened
        if currentFile.map(Self.key(for:)) == closing.id {
            currentFile = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].url
        }
    }

    func closeCurrentTab() {
        if let index = currentIndex { close(documents[index]) }
    }

    func closeOthers(_ keep: OpenDocument) {
        for document in documents where document.id != keep.id { close(document) }
    }

    func closeAll() {
        for document in documents { close(document) }
    }

    func updateText(_ newText: String) {
        guard let index = currentIndex else { return }
        setText(newText, at: index)
    }

    private func setText(_ newText: String, at index: Int) {
        guard documents[index].text != newText else { return }
        documents[index].text = newText
        documents[index].isDirty = true
        documents[index].version += 1
        guard lspReady, Self.isPython(documents[index].url) else { return }
        try? lsp?.notify("textDocument/didChange", params: [
            "textDocument": ["uri": .string(documents[index].url.absoluteString), "version": .int(documents[index].version)],
            "contentChanges": [["text": .string(newText)]],
        ])
        if documents[index].id == currentDocumentID { scheduleOutlineRefresh(after: .milliseconds(500)) }
    }

    /// ⌘S: formats first when Format on Save is on.
    func save() {
        if let index = currentIndex { save(documentID: documents[index].id) }
    }

    /// Save All menu command: like ⌘S for every unsaved document.
    func saveAll() {
        for document in documents where document.isDirty { save(documentID: document.id) }
    }

    /// Saves every unsaved document immediately, without formatting (before runs, on close/quit).
    func saveAllNow() {
        for index in documents.indices where documents[index].isDirty { save(at: index) }
    }

    private func save(documentID id: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let url = documents[index].url
        guard formatOnSave, Self.isPython(url), !isReadOnly(url) else {
            save(at: index)
            return
        }
        Task {
            await format(documentID: id, explicit: false)
            if let index = documents.firstIndex(where: { $0.id == id }) { save(at: index) }
        }
    }

    /// Format Document command.
    func formatDocument() { transformCurrentDocument(.format) }

    /// Fix All / Organize Imports (ruff) on the current document.
    func transformCurrentDocument(_ operation: CodeFormatter.Operation) {
        guard let index = currentIndex, !isReadOnly(documents[index].url) else { return }
        let id = documents[index].id
        Task { await format(documentID: id, operation: operation, explicit: true) }
    }

    /// Replaces the document's text with the formatter's output (an undoable edit in the editor).
    private func format(documentID id: String, operation: CodeFormatter.Operation = .format, explicit: Bool) async {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let document = documents[index]
        guard let formatter = CodeFormatter.locate(interpreter: interpreter) else {
            if explicit { flashStatus("No formatter found — uv tool install ruff (or pip install black)") }
            return
        }
        do {
            let formatted = try await formatter.format(
                document.text, file: document.url, operation: operation,
                environment: ToolLocator.environment(interpreter: interpreter), currentDirectory: rootURL)
            // Skip if the user kept typing while the formatter ran.
            guard let index = documents.firstIndex(where: { $0.id == id }), documents[index].text == document.text else { return }
            if formatted.isEmpty && !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            setText(formatted, at: index)
            if explicit && formatted == document.text {
                flashStatus(operation == .format ? "\(formatter.name): already formatted" : "\(operation.title): nothing to change")
            }
        } catch {
            flashStatus(error.localizedDescription)
        }
    }

    @discardableResult
    private func save(at index: Int) -> Bool {
        let document = documents[index]
        guard !isReadOnly(document.url) else { return false }
        do {
            try document.text.write(to: document.url, atomically: true, encoding: .utf8)
            documents[index].isDirty = false
            if let remote = Self.boardPath(ofCached: document.url) {
                // A board file opened from the sidebar: saving writes it back to the board.
                board.upload(contents: [(remote, Data(document.text.utf8))], force: true)
            }
            if lspReady, Self.isPython(document.url) {
                try? lsp?.notify("textDocument/didSave", params: ["textDocument": ["uri": .string(document.url.absoluteString)]])
            }
            return true
        } catch {
            flashStatus("Save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// For dirty documents about to be closed: asks Save / Don't Save / Cancel.
    /// Returns false if the user cancelled (or a save failed).
    func confirmDiscardOrSave(_ dirty: [OpenDocument]) -> Bool {
        let dirty = dirty.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Do you want to save the changes you made to \(dirty[0].name)?"
            : "Do you want to save the changes to \(dirty.count) files?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for document in dirty {
                guard let index = documents.firstIndex(where: { $0.id == document.id }), save(at: index) else { return false }
            }
            return true
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func reveal(_ problem: ProblemItem) {
        let url = URL(fileURLWithPath: problem.path)
        if currentFile.map(Self.key(for:)) != problem.path { openFile(url) }
        revealTarget = RevealTarget(position: problem.diagnostic.start)
    }

    // MARK: - Language features

    func completions(at offset: Int) async -> [CompletionItem] {
        guard case let (lsp, params)? = positionRequest(at: offset),
              let result = try? await lsp.request("textDocument/completion", params: params)
        else { return [] }
        return CompletionItem.parseList(result)
    }

    func hover(at offset: Int) async -> String? {
        guard case let (lsp, params)? = positionRequest(at: offset),
              let result = try? await lsp.request("textDocument/hover", params: params)
        else { return nil }
        return HoverContent.parse(result).map { String($0.prefix(4000)) }
    }

    func jumpToDefinition(at offset: Int) async {
        guard let url = currentFile, case let (lsp, params)? = positionRequest(at: offset) else { return }
        let origin = LineIndex(text).position(of: offset)
        let result = try? await lsp.request("textDocument/definition", params: params)
        guard let location = result.map(Location.parseAll)?.first,
              let target = URL(string: location.uri), target.isFileURL
        else {
            flashStatus("No definition found")
            return
        }
        backStack.append(NavigationPoint(url: url, position: origin))
        if backStack.count > 100 { backStack.removeFirst() }
        navigate(to: URL(fileURLWithPath: target.path), position: location.start)
    }

    /// Re-fetches the current file's symbols, debounced while typing.
    private func scheduleOutlineRefresh(after delay: Duration) {
        outlineTask?.cancel()
        outlineTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            guard self.lspReady, self.isPythonFile, let url = self.currentFile, let lsp = self.lsp else {
                self.outline = []
                return
            }
            let result = try? await lsp.request("textDocument/documentSymbol",
                                                params: ["textDocument": ["uri": .string(url.absoluteString)]])
            guard !Task.isCancelled, self.currentFile == url else { return }
            self.outline = result.map(OutlineSymbol.parse) ?? []
        }
    }

    func reveal(_ symbol: OutlineSymbol) {
        revealTarget = RevealTarget(position: symbol.position)
    }

    func signatureHelp(at offset: Int) async -> SignatureInfo? {
        guard case let (lsp, params)? = positionRequest(at: offset),
              let result = try? await lsp.request("textDocument/signatureHelp", params: params)
        else { return nil }
        return SignatureInfo.parse(result)
    }

    /// Fills the References panel with every use of the symbol at `offset`.
    func findReferences(at offset: Int) async {
        guard case let (lsp, params)? = positionRequest(at: offset), case .object(var request) = params else { return }
        let ns = text as NSString
        referencesQuery = Identifier.wordRange(in: ns, at: offset).map(ns.substring(with:))
            ?? Identifier.wordRange(in: ns, at: offset - 1).map(ns.substring(with:)) ?? "symbol"
        request["context"] = ["includeDeclaration": true]
        let result = try? await lsp.request("textDocument/references", params: .object(request))
        let locations = result.map(Location.parseAll) ?? []
        var cache: [String: [Substring]] = [:]
        references = locations.compactMap { location -> ReferenceItem? in
            guard let uri = URL(string: location.uri), uri.isFileURL else { return nil }
            let url = URL(fileURLWithPath: uri.path)
            let key = Self.key(for: url)
            if cache[key] == nil {
                let source = documents.first { $0.id == key }?.text ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                cache[key] = source.split(separator: "\n", omittingEmptySubsequences: false)
            }
            let lines = cache[key] ?? []
            let line = lines.indices.contains(location.start.line) ? lines[location.start.line] : ""
            return ReferenceItem(url: url, position: location.start,
                                 lineText: line.trimmingCharacters(in: .whitespaces))
        }
        .sorted { (Self.key(for: $0.url), $0.position.line, $0.position.character)
                < (Self.key(for: $1.url), $1.position.line, $1.position.character) }
        bottomTab = .references
        if references.isEmpty { flashStatus("No references found") }
    }

    func openReference(_ item: ReferenceItem) {
        if let url = currentFile {
            backStack.append(NavigationPoint(url: url, position: LineIndex(text).position(of: caretOffset)))
            if backStack.count > 100 { backStack.removeFirst() }
        }
        navigate(to: item.url, position: item.position)
    }

    /// Prompts for a new name and applies the language server's rename across files.
    /// Changed files that aren't open are opened as unsaved tabs, so nothing is written without ⌘S.
    func renameSymbol(at offset: Int) async {
        guard case let (lsp, params)? = positionRequest(at: offset), case .object(var request) = params else { return }
        let ns = text as NSString
        var oldName = Identifier.wordRange(in: ns, at: offset).map(ns.substring(with:))
            ?? Identifier.wordRange(in: ns, at: offset - 1).map(ns.substring(with:))
        if let prepared = try? await lsp.request("textDocument/prepareRename", params: params) {
            guard let range = PrepareRename.parse(prepared) else {
                flashStatus("Can't rename this symbol")
                return
            }
            oldName = range.placeholder ?? ns.substring(with: LineIndex(text).range(from: range.start, to: range.end))
        }
        guard let oldName, !oldName.isEmpty else {
            flashStatus("Put the caret on a symbol to rename it")
            return
        }
        guard let newName = Self.promptForName(oldName), newName != oldName else { return }
        request["newName"] = .string(newName)
        let result: JSONValue
        do {
            result = try await lsp.request("textDocument/rename", params: .object(request))
        } catch {
            flashStatus("Rename failed: \(error.localizedDescription)")
            return
        }
        let changes = WorkspaceEdit.parse(result)
        var occurrences = 0, files = 0
        for (uri, edits) in changes.sorted(by: { $0.key < $1.key }) {
            guard let parsed = URL(string: uri), parsed.isFileURL else { continue }
            let url = URL(fileURLWithPath: parsed.path)
            guard !isReadOnly(url) else { continue }
            let key = Self.key(for: url)
            if let index = documents.firstIndex(where: { $0.id == key }) {
                setText(TextEdit.apply(edits, to: documents[index].text), at: index)
            } else {
                guard let original = try? String(contentsOf: url, encoding: .utf8) else { continue }
                var document = OpenDocument(url: url, text: TextEdit.apply(edits, to: original))
                document.isDirty = true
                documents.append(document)
                sendDidOpen(document)
            }
            occurrences += edits.count
            files += 1
        }
        flashStatus(files == 0 ? "Nothing to rename"
                    : "Renamed \(occurrences) occurrence\(occurrences == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s") — ⌥⌘S to save")
    }

    private static func promptForName(_ oldName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename '\(oldName)'"
        alert.informativeText = "All references in the project will be updated. Changed files stay unsaved until you save them."
        let field = NSTextField(string: oldName)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if Identifier.isValidPythonName(name) { return name }
            alert.informativeText = "'\(name)' is not a valid Python identifier."
        }
        return nil
    }

    func goBack() {
        guard let point = backStack.popLast() else { return }
        navigate(to: point.url, position: point.position)
    }

    private func navigate(to url: URL, position: TextPosition) {
        if currentFile.map(Self.key(for:)) != Self.key(for: url) { openFile(url) }
        guard currentFile.map(Self.key(for:)) == Self.key(for: url) else { return }
        revealTarget = RevealTarget(position: position)
    }

    private func positionRequest(at offset: Int) -> (LSPClient, JSONValue)? {
        guard lspReady, isPythonFile, let url = currentFile, let lsp else { return nil }
        let position = LineIndex(text).position(of: offset)
        return (lsp, ["textDocument": ["uri": .string(url.absoluteString)], "position": position.json])
    }

    func flashStatus(_ message: String) {
        let previous = lspStatus
        lspStatus = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if lspStatus == message { lspStatus = previous }
        }
    }

    // MARK: - Language server

    func restartLanguageServer() async {
        guard let rootURL else { return }
        await stopLanguageServer()
        await startLanguageServer(root: rootURL)
    }

    private func startLanguageServer(root: URL) async {
        guard let (spec, executable) = LanguageServerSpec.locate(interpreter: interpreter) else {
            lspStatus = "No Python language server — \(LanguageServerSpec.installHint)"
            return
        }
        lspName = spec.name
        let pythonPath = interpreter?.path
        let stubs = MicroPythonStubs.isInstalled ? MicroPythonStubs.directory : nil
        let client = LSPClient()
        client.configurationProvider = { items in
            LanguageServerSpec.configuration(items: items, pythonPath: pythonPath, stubs: stubs)
        }
        client.onNotification = { method, params in
            Task { @MainActor in self.handleNotification(client, method: method, params: params) }
        }
        client.onExit = { status in
            Task { @MainActor in
                guard self.lsp === client else { return }
                self.lsp = nil
                self.lspReady = false
                self.lspStatus = "\(spec.name) exited (status \(status))"
            }
        }

        do {
            try client.start(executable: executable, arguments: spec.arguments,
                             environment: ToolLocator.environment(interpreter: interpreter), currentDirectory: root)
            lsp = client
            lspStatus = "\(spec.name): starting…"
            _ = try await client.request("initialize", params: Self.initializeParams(root: root))
            guard lsp === client else { return }  // folder changed while initializing
            try client.notify("initialized", params: [:])
            try client.notify("workspace/didChangeConfiguration", params: ["settings": [:]])
            lspReady = true
            lspStatus = stubs == nil ? "\(spec.name): ready — Python → Install MicroPython Stubs for machine/network completion"
                : "\(spec.name): ready (MicroPython stubs)"
            scheduleOutlineRefresh(after: .zero)
            documents.forEach(sendDidOpen)
        } catch {
            if lsp === client { lsp = nil }
            lspStatus = "\(spec.name) failed: \(error.localizedDescription)"
        }
    }

    private func stopLanguageServer() async {
        guard let client = lsp else { return }
        lsp = nil
        lspReady = false
        client.onNotification = nil
        client.onExit = nil
        lspStatus = "\(lspName): stopped"
        await client.shutdown()
    }

    private func handleNotification(_ client: LSPClient, method: String, params: JSONValue) {
        guard lsp === client else { return }
        switch method {
        case "textDocument/publishDiagnostics":
            guard let published = Diagnostic.parsePublish(params), let url = URL(string: published.uri) else { return }
            let key = Self.key(for: url)
            // Hints ("x is not accessed") are too noisy for the Problems list.
            let shown = published.diagnostics.filter { $0.severity != .hint }
            if shown.isEmpty {
                diagnostics.removeValue(forKey: key)
            } else {
                diagnostics[key] = shown
            }
        case "window/showMessage":
            if let message = params["message"]?.stringValue { lspStatus = "\(lspName): \(message)" }
        default:
            break
        }
    }

    private func sendDidOpen(_ document: OpenDocument) {
        guard lspReady, Self.isPython(document.url) else { return }
        try? lsp?.notify("textDocument/didOpen", params: [
            "textDocument": [
                "uri": .string(document.url.absoluteString),
                "languageId": "python",
                "version": .int(document.version),
                "text": .string(document.text),
            ],
        ])
    }

    private func sendDidClose(_ document: OpenDocument) {
        guard lspReady, Self.isPython(document.url) else { return }
        try? lsp?.notify("textDocument/didClose", params: ["textDocument": ["uri": .string(document.url.absoluteString)]])
    }

    private static func initializeParams(root: URL) -> JSONValue {
        let textDocument: JSONValue = [
            "synchronization": ["didSave": true, "dynamicRegistration": false],
            "publishDiagnostics": ["relatedInformation": false],
            "completion": [
                "completionItem": ["snippetSupport": false, "documentationFormat": ["markdown", "plaintext"]],
            ],
            "hover": ["contentFormat": ["markdown", "plaintext"]],
            "definition": ["linkSupport": false],
            "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
            "references": [:],
            "rename": ["prepareSupport": true],
            "signatureHelp": [
                "signatureInformation": [
                    "documentationFormat": ["markdown", "plaintext"],
                    "parameterInformation": ["labelOffsetSupport": true],
                    "activeParameterSupport": true,
                ],
            ],
        ]
        let workspace: JSONValue = ["configuration": true, "workspaceFolders": true,
                                    "workspaceEdit": ["documentChanges": true]]
        return [
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": ["name": "ESPIDE", "version": "0.1.0"],
            "rootUri": .string(root.absoluteString),
            "workspaceFolders": [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]],
            "capabilities": [
                "textDocument": textDocument,
                "workspace": workspace,
                "general": ["positionEncodings": ["utf-16"]],
            ],
        ]
    }

    // MARK: - Board

    /// Runs the current file (or main.py) on the board without saving it there.
    func runOnBoard() {
        guard let file = runTarget() else {
            flashStatus("Nothing to run: open a .py file (or add main.py)")
            return
        }
        saveAllNow()
        let key = Self.key(for: file)
        let code = documents.first { $0.id == key }?.text ?? (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        board.run(code, name: relativePath(file))
    }

    /// The current file if it's a .py file, else the project's main.py.
    private func runTarget() -> URL? {
        if let currentFile, currentFile.pathExtension == "py" { return currentFile }
        return Self.firstFile(named: "main.py", in: fileTree)
    }

    /// Where a project file lives on the board: the same relative path under /.
    func boardPath(for url: URL) -> String? {
        guard let rootURL else { return nil }
        let path = Self.key(for: url), root = Self.key(for: rootURL)
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count))
    }

    /// Uploads the current file to the same path on the board.
    func uploadCurrentFile() {
        guard let currentFile, let remote = boardPath(for: currentFile) else {
            flashStatus("Open a project file to upload")
            return
        }
        saveAllNow()
        board.upload([(currentFile, remote)], force: true)
    }

    /// Uploads every changed .py file of the project, keeping folders (lib/, …).
    func syncProject() {
        guard let rootURL else { return }
        saveAllNow()
        let files = ProjectSync.files(in: rootURL)
        guard !files.isEmpty else {
            flashStatus("No .py files to upload")
            return
        }
        board.upload(files.compactMap { url in boardPath(for: url).map { (url, $0) } })
    }

    /// The board path of a file opened from the Board sidebar (a copy in the cache folder), else nil.
    nonisolated static func boardPath(ofCached url: URL) -> String? {
        let path = key(for: url), cache = key(for: boardCacheURL)
        guard path.hasPrefix(cache + "/") else { return nil }
        return String(path.dropFirst(cache.count))
    }

    /// Board → Install Library…
    func promptInstallLibrary() {
        let alert = NSAlert()
        alert.messageText = "Install a library on the board"
        alert.informativeText = "A micropython-lib package (ssd1306, umqtt.simple, aioble, …), "
            + "github:user/repo/file.py, or a URL to a .py file. Files go to /lib."
        let field = NSTextField(string: "")
        field.placeholderString = "ssd1306"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let spec = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !spec.isEmpty { board.installLibrary(spec) }
    }

    /// GPIO usage of the project's .py files (open editors' unsaved text included).
    func pinMap() -> [PinScanner.Pin] {
        guard let rootURL else { return [] }
        let sources = ProjectSync.files(in: rootURL).filter { $0.pathExtension == "py" }.compactMap { url -> (URL, String)? in
            if let open = documents.first(where: { $0.id == Self.key(for: url) }) { return (url, open.text) }
            return (try? String(contentsOf: url, encoding: .utf8)).map { (url, $0) }
        }
        return PinScanner.pins(PinScanner.scan(sources), usesWiFi: PinScanner.usesWiFi(sources))
    }

    func reveal(_ use: PinScanner.Use) {
        navigate(to: use.file, position: TextPosition(line: use.line, character: 0))
    }

    /// Opens a board file for editing (a copy in the cache folder; ⌘S writes it back).
    func openBoardFile(_ file: DeviceFile) {
        guard !file.isDirectory else { return }
        Task {
            guard let data = await board.download(file.path) else { return }
            let url = Self.boardCacheURL.appendingPathComponent(String(file.path.dropFirst()))
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            } catch {
                flashStatus(error.localizedDescription)
                return
            }
            // Re-read the fresh copy if an older one is already open.
            if let index = documents.firstIndex(where: { $0.id == Self.key(for: url) }), !documents[index].isDirty {
                documents[index].text = String(decoding: data, as: UTF8.self)
                documents[index].version += 1
            }
            openFile(url)
        }
    }

    /// Copies a board file into the project at the same relative path.
    func downloadToProject(_ file: DeviceFile) {
        guard let rootURL, !file.isDirectory else { return }
        let target = rootURL.appendingPathComponent(String(file.path.dropFirst()))
        if FileManager.default.fileExists(atPath: target.path) {
            let alert = NSAlert()
            alert.messageText = "Replace \(relativePath(target)) with the board's copy?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task {
            guard let data = await board.download(file.path) else { return }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target)
            } catch {
                flashStatus(error.localizedDescription)
                return
            }
            if let index = documents.firstIndex(where: { $0.id == Self.key(for: target) }), !documents[index].isDirty {
                setText(String(decoding: data, as: UTF8.self), at: index)
                documents[index].isDirty = false
            }
            reloadTree()
            flashStatus("Downloaded \(file.path)")
        }
    }

    func deleteBoardFile(_ file: DeviceFile) {
        let alert = NSAlert()
        alert.messageText = "Delete \(file.path) from the board?"
        alert.informativeText = file.isDirectory ? "The folder and everything in it will be deleted." : "This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        board.delete(file.path)
    }

    /// Sends the editor selection, or the caret's line, to the board's REPL.
    func sendSelectionToREPL() {
        let ns = text as NSString
        guard ns.length > 0 else { return }
        let selection = NSRange(location: min(selectedRange.location, ns.length),
                                length: min(selectedRange.length, ns.length - min(selectedRange.location, ns.length)))
        let range = selection.length > 0 ? selection : ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let code = ns.substring(with: range)
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flashStatus("Nothing to send — select code or put the caret on a line")
            return
        }
        board.paste(code)
    }

    /// Installs micropython-esp32-stubs into ESPIDE's support folder and restarts pyright.
    func installStubs() {
        guard let (executable, arguments) = MicroPythonStubs.installCommand(interpreter: interpreter) else {
            flashStatus("Neither uv nor python3 found — brew install uv")
            return
        }
        bottomTab = .output
        Task {
            let status = await board.runTool(executable, arguments, title: "Installing MicroPython stubs")
            if status == 0 && MicroPythonStubs.isInstalled {
                flashStatus("MicroPython stubs installed")
                await restartLanguageServer()
            } else {
                flashStatus("Installing stubs failed (status \(status)) — see Output")
            }
        }
    }

    /// Downloads the newest stable image for a chip family (cached by file name).
    func downloadLatestFirmware(_ family: Firmware.Family) async -> URL? {
        do {
            let (page, _) = try await URLSession.shared.data(from: family.downloadPage)
            guard let remote = Firmware.latestImage(onPage: String(decoding: page, as: UTF8.self), family: family) else {
                flashStatus("No firmware found on \(family.downloadPage.absoluteString)")
                return nil
            }
            let folder = Self.boardCacheURL.deletingLastPathComponent().appendingPathComponent("firmware")
            let local = folder.appendingPathComponent(remote.lastPathComponent)
            if FileManager.default.fileExists(atPath: local.path) { return local }
            flashStatus("Downloading \(remote.lastPathComponent)…")
            let (downloaded, response) = try await URLSession.shared.download(from: remote)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                flashStatus("Download failed: \(remote.absoluteString)")
                return nil
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: downloaded, to: local)
            return local
        } catch {
            flashStatus("Download failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Board → Scan I2C Bus…: asks for the pins (remembered), then lists what answers.
    func scanI2C() {
        let defaults = UserDefaults.standard
        let alert = NSAlert()
        alert.messageText = "Scan I2C bus"
        alert.informativeText = "GPIO numbers of the bus to scan (software I2C, any pins)."
        let sda = NSTextField(string: String(defaults.object(forKey: "i2cSDA") as? Int ?? 21))
        let scl = NSTextField(string: String(defaults.object(forKey: "i2cSCL") as? Int ?? 22))
        let grid = NSGridView(views: [[NSTextField(labelWithString: "SDA"), sda], [NSTextField(labelWithString: "SCL"), scl]])
        grid.frame = NSRect(x: 0, y: 0, width: 160, height: 56)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Scan")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = sda
        guard alert.runModal() == .alertFirstButtonReturn,
              let sdaPin = Int(sda.stringValue.trimmingCharacters(in: .whitespaces)),
              let sclPin = Int(scl.stringValue.trimmingCharacters(in: .whitespaces))
        else { return }
        defaults.set(sdaPin, forKey: "i2cSDA")
        defaults.set(sclPin, forKey: "i2cSCL")
        board.scanI2C(sda: sdaPin, scl: sclPin)
    }

    /// Shows the Flash Firmware sheet.
    var showFirmwareSheet = false

    nonisolated static let boardCacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ESPIDE/board", isDirectory: true)

    // MARK: - Helpers

    nonisolated static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    nonisolated static func isPython(_ url: URL) -> Bool {
        ["py", "pyi", "pyw"].contains(url.pathExtension)
    }

    func relativePath(_ url: URL) -> String {
        if let remote = Self.boardPath(ofCached: url) { return "board:" + remote }
        guard let root = rootURL?.path, url.path.hasPrefix(root + "/") else { return url.path }
        return String(url.path.dropFirst(root.count + 1))
    }

    private static func firstFile(named name: String, in nodes: [FileNode]) -> URL? {
        nodes.first(where: { !$0.isDirectory && $0.name == name })?.url
    }

    private static func firstPythonFile(in nodes: [FileNode]) -> URL? {
        nodes.first(where: { !$0.isDirectory && isPython($0.url) })?.url
    }
}
