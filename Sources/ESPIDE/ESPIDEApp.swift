import ESPIDECore
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a dead language server's stdin must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    weak var workspace: Workspace?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        guard workspace.confirmDiscardOrSave(workspace.documents) else { return .terminateCancel }
        workspace.board.disconnect()  // release the serial port
        return .terminateNow
    }
}

@main
struct ESPIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var workspace = Workspace()

    var body: some Scene {
        WindowGroup("ESP32 IDE") {
            ContentView()
                .environment(workspace)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { appDelegate.workspace = workspace }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { workspace.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") { workspace.closeCurrentTab() }
                    .keyboardShortcut("w")
                    .disabled(workspace.currentFile == nil)
                Button("Save") { workspace.save() }
                    .keyboardShortcut("s")
                    .disabled(workspace.currentFile == nil)
                Button("Save All") { workspace.saveAll() }
                    .keyboardShortcut("s", modifiers: [.option, .command])
                    .disabled(!workspace.hasUnsavedChanges)
            }
            CommandMenu("Navigate") {
                Button("Jump to Definition") {
                    Task { await workspace.jumpToDefinition(at: workspace.caretOffset) }
                }
                .keyboardShortcut("j", modifiers: [.control, .command])
                .disabled(!workspace.isPythonFile)
                Button("Find References") {
                    Task { await workspace.findReferences(at: workspace.caretOffset) }
                }
                .keyboardShortcut("r", modifiers: [.option, .command])
                .disabled(!workspace.isPythonFile)
                Button("Rename Symbol…") {
                    Task { await workspace.renameSymbol(at: workspace.caretOffset) }
                }
                .keyboardShortcut("e", modifiers: [.control, .command])
                .disabled(!workspace.isPythonFile || workspace.isReadOnly)
                Divider()
                Button("Go Back") { workspace.goBack() }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
                    .disabled(!workspace.canGoBack)
                Divider()
                Button("Next Tab") { workspace.selectAdjacentTab(1) }
                    .keyboardShortcut("]", modifiers: [.shift, .command])
                    .disabled(workspace.documents.count < 2)
                Button("Previous Tab") { workspace.selectAdjacentTab(-1) }
                    .keyboardShortcut("[", modifiers: [.shift, .command])
                    .disabled(workspace.documents.count < 2)
            }
            CommandMenu("Board") {
                Button(workspace.board.isConnected ? "Disconnect" : "Connect") { workspace.board.toggleConnection() }
                    .keyboardShortcut("k", modifiers: [.shift, .command])
                Divider()
                Button("Run File on Board") { workspace.runOnBoard() }
                    .keyboardShortcut("r")
                    .disabled(!workspace.board.isIdle)
                Button("Stop") { workspace.board.isRunning ? workspace.board.stop() : workspace.board.interrupt() }
                    .keyboardShortcut(".")
                    .disabled(!workspace.board.isConnected)
                Button("Soft Reset (run main.py)") { workspace.board.softReset() }
                    .keyboardShortcut("r", modifiers: [.shift, .command])
                    .disabled(!workspace.board.isIdle)
                Divider()
                Button("Upload Current File") { workspace.uploadCurrentFile() }
                    .keyboardShortcut("u")
                    .disabled(!workspace.board.isIdle || workspace.currentFile == nil)
                Button("Sync Project to Board") { workspace.syncProject() }
                    .keyboardShortcut("s", modifiers: [.shift, .command])
                    .disabled(!workspace.board.isIdle || workspace.rootURL == nil)
                Button("Reload Board Files") { workspace.board.refreshFiles() }
                    .disabled(!workspace.board.isIdle)
                Divider()
                Button("Install Library…") { workspace.promptInstallLibrary() }
                    .disabled(!workspace.board.isIdle)
                Button("Scan I2C Bus…") { workspace.scanI2C() }
                    .disabled(!workspace.board.isIdle)
                Button("Flash MicroPython Firmware…") { workspace.showFirmwareSheet = true }
                    .disabled(workspace.board.isRunning || workspace.board.isFlashing)
                Divider()
                Button("Send Selection to REPL") { workspace.sendSelectionToREPL() }
                    .keyboardShortcut(.return, modifiers: [.control])
                    .disabled(!workspace.board.isIdle)
                Button("Show REPL") { workspace.bottomTab = .repl }
                    .keyboardShortcut("p", modifiers: [.control, .command])
                Button("Show Plot") { workspace.bottomTab = .plot }
                    .keyboardShortcut("l", modifiers: [.control, .command])
            }
            CommandMenu("Python") {
                Button("Format Document") { workspace.formatDocument() }
                    .keyboardShortcut("f", modifiers: [.shift, .option])
                    .disabled(!workspace.isPythonFile || workspace.isReadOnly)
                Button("Fix All (ruff)") { workspace.transformCurrentDocument(.fixAll) }
                    .keyboardShortcut("f", modifiers: [.shift, .option, .command])
                    .disabled(!workspace.isPythonFile || workspace.isReadOnly)
                Button("Organize Imports") { workspace.transformCurrentDocument(.organizeImports) }
                    .keyboardShortcut("o", modifiers: [.shift, .option])
                    .disabled(!workspace.isPythonFile || workspace.isReadOnly)
                Toggle("Format on Save", isOn: Bindable(workspace).formatOnSave)
                Divider()
                Button(MicroPythonStubs.isInstalled ? "Update MicroPython Stubs" : "Install MicroPython Stubs") {
                    workspace.installStubs()
                }
                Button("Choose Interpreter…") { workspace.presentInterpreterPanel() }
                    .disabled(workspace.rootURL == nil)
                Button("Restart Language Server") { Task { await workspace.restartLanguageServer() } }
            }
        }
    }
}
