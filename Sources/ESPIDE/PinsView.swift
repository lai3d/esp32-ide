import ESPIDECore
import SwiftUI

/// Sidebar: which GPIOs the project uses, with classic-ESP32 warnings.
struct PinsView: View {
    @Environment(Workspace.self) private var workspace
    @State private var pins: [PinScanner.Pin] = []

    var body: some View {
        VStack(spacing: 0) {
            if pins.isEmpty {
                Text(workspace.rootURL == nil ? "Open a project" : "No GPIOs found in the project's .py files")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(pins) { pin in
                        Section {
                            ForEach(pin.notes, id: \.self) { note in
                                Label(note.message, systemImage: Self.symbol(note.severity))
                                    .foregroundStyle(Self.color(note.severity))
                                    .font(.caption)
                            }
                            ForEach(pin.uses) { use in
                                Button { workspace.reveal(use) } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\(use.file.lastPathComponent):\(use.line + 1)  \(use.kind.rawValue)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(use.text)
                                            .font(.system(.caption, design: .monospaced))
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .help(workspace.relativePath(use.file))
                            }
                        } header: {
                            HStack {
                                Text("GPIO \(pin.number)").font(.headline.monospacedDigit())
                                if let severity = pin.severity, severity > .info {
                                    Image(systemName: Self.symbol(severity)).foregroundStyle(Self.color(severity))
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Rescan the project")
                Spacer()
                Menu {
                    Button {
                        workspace.setPinChip(nil)
                    } label: {
                        if workspace.pinChipIsAutomatic { Label("Automatic (from the board)", systemImage: "checkmark") }
                        else { Text("Automatic (from the board)") }
                    }
                    Divider()
                    ForEach(PinScanner.Chip.all, id: \.name) { chip in
                        Button {
                            workspace.setPinChip(chip)
                        } label: {
                            if !workspace.pinChipIsAutomatic && workspace.pinChip == chip { Label(chip.name, systemImage: "checkmark") }
                            else { Text(chip.name) }
                        }
                    }
                } label: {
                    Text("\(pins.count) GPIOs · \(workspace.pinChip.name) rules").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Which chip's pin rules to apply")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .onAppear(perform: refresh)
        .onChange(of: workspace.hasUnsavedChanges) { refresh() }
        .onChange(of: workspace.fileTree.count) { refresh() }
        .onChange(of: workspace.pinChip) { refresh() }
    }

    private func refresh() { pins = workspace.pinMap() }

    static func symbol(_ severity: PinScanner.Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    static func color(_ severity: PinScanner.Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}
