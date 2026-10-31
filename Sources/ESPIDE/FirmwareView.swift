import ESPIDECore
import SwiftUI

/// Board → Flash MicroPython Firmware…
struct FirmwareView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("firmwareFamily") private var family: Firmware.Family = .esp32
    @State private var source: Source = .latest
    @State private var localImage: URL?
    @State private var erase = false
    @State private var working: String?

    enum Source: Hashable { case latest, file }

    var body: some View {
        let board = workspace.board
        VStack(alignment: .leading, spacing: 14) {
            Text("Flash MicroPython").font(.title2.bold())
            Form {
                LabeledContent("Port") {
                    Text(board.port ?? "No board found").foregroundStyle(board.port == nil ? .red : .primary)
                }
                HStack {
                    Picker("Chip", selection: $family) {
                        ForEach(Firmware.Family.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Detect") {
                        Task {
                            working = "Detecting chip…"
                            if let detected = await board.detectChip(interpreter: workspace.interpreter) { family = detected }
                            working = nil
                        }
                    }
                    .disabled(board.port == nil || working != nil)
                }
                Picker("Firmware", selection: $source) {
                    Text("Latest stable from micropython.org").tag(Source.latest)
                    Text(localImage?.lastPathComponent ?? "Choose a .bin file…").tag(Source.file)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: source) { _, new in if new == .file && localImage == nil { chooseFile() } }
                Toggle("Erase the whole flash first (deletes all files on the board)", isOn: $erase)
            }
            if let progress = board.flashProgress {
                ProgressView(value: progress) { Text("Writing… \(Int(progress * 100))%").font(.caption) }
            } else if let working {
                ProgressView { Text(working).font(.caption) }.progressViewStyle(.linear)
            }
            Text("Output appears in the Output panel. The board disconnects while esptool runs and reconnects afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Link("micropython.org/download", destination: family.downloadPage).font(.caption)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Flash") { flash() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(board.port == nil || working != nil || board.isFlashing
                              || (source == .file && localImage == nil))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a MicroPython firmware image (.bin)"
        if panel.runModal() == .OK, let url = panel.url {
            localImage = url
        } else if localImage == nil {
            source = .latest
        }
    }

    private func flash() {
        Task {
            let image: URL?
            if source == .file {
                image = localImage
            } else {
                working = "Downloading firmware…"
                image = await workspace.downloadLatestFirmware(family)
            }
            working = image == nil ? nil : "Flashing…"
            if let image,
               await workspace.board.flash(image: image, family: family, erase: erase, interpreter: workspace.interpreter) {
                dismiss()
            }
            working = nil
        }
    }
}
