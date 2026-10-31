import ESPIDECore
import SwiftUI

/// Toolbar: serial port menu and Connect / Disconnect.
struct BoardPicker: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let board = workspace.board
        Menu {
            if board.ports.isEmpty {
                Text("No boards found — plug one in with a data USB cable")
            }
            ForEach(board.ports, id: \.self) { port in
                Button {
                    if board.isConnected && board.connectedPort != port { board.disconnect() }
                    board.port = port
                } label: {
                    if port == board.port { Label(port, systemImage: "checkmark") } else { Text(port) }
                }
            }
            Divider()
            Button("Refresh") { board.refreshPorts() }
        } label: {
            Label(Self.short(board.port) ?? "No board", systemImage: "cable.connector")
        }
        .help("Serial port")
        .disabled(board.isRunning)
        Button { board.toggleConnection() } label: {
            Label(board.isConnected ? "Disconnect" : "Connect",
                  systemImage: board.isConnected ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
        }
        .help(board.isConnected ? "Disconnect (frees the port for mpremote / Thonny)" : "Connect to the board (⇧⌘K)")
        .disabled(board.port == nil && !board.isConnected)
    }

    static func short(_ port: String?) -> String? {
        port?.replacingOccurrences(of: "/dev/cu.", with: "")
    }
}

/// Sidebar: the files on the board's flash.
struct BoardFilesView: View {
    @Environment(Workspace.self) private var workspace
    @State private var selection: String?

    var body: some View {
        let board = workspace.board
        VStack(spacing: 0) {
            if !board.isConnected {
                placeholder("Connect a board to see its files")
            } else if !board.filesLoaded {
                placeholder(board.isRunning ? "Stop the program to read files" : "Reading files…")
            } else if board.files.isEmpty {
                placeholder("The board's filesystem is empty")
            } else {
                List(board.files, children: \.children, selection: $selection) { file in
                    HStack {
                        Label(file.name, systemImage: file.isDirectory ? "folder" : "doc.text")
                            .lineLimit(1)
                        Spacer()
                        if !file.isDirectory {
                            Text(Self.size(file.size)).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .tag(file.path)
                    .contextMenu {
                        if !file.isDirectory {
                            Button("Open") { workspace.openBoardFile(file) }
                            Button("Download to Project") { workspace.downloadToProject(file) }
                        }
                        Button("Delete…", role: .destructive) { workspace.deleteBoardFile(file) }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selection) { _, path in
                    if let path, let file = Self.find(path, in: board.files), !file.isDirectory {
                        workspace.openBoardFile(file)
                    }
                }
            }
            Divider()
            HStack {
                Button { board.refreshFiles() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload the board's files")
                Spacer()
                Text(Self.total(board.files)).font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!board.isIdle)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func find(_ path: String, in files: [DeviceFile]) -> DeviceFile? {
        for file in files {
            if file.path == path { return file }
            if let hit = find(path, in: file.children ?? []) { return hit }
        }
        return nil
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func total(_ files: [DeviceFile]) -> String {
        func sum(_ files: [DeviceFile]) -> (Int, Int) {
            files.reduce((0, 0)) { acc, file in
                let (count, bytes) = file.isDirectory ? sum(file.children ?? []) : (1, file.size)
                return (acc.0 + count, acc.1 + bytes)
            }
        }
        let (count, bytes) = sum(files)
        return count == 0 ? "" : "\(count) files, \(size(bytes))"
    }
}
