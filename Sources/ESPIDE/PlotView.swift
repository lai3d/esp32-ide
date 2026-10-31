import Charts
import ESPIDECore
import SwiftUI

/// Bottom panel: a live chart of numbers the board prints (`print(t)`, `print(t, p)` or `print("t=", t)`).
struct PlotView: View {
    @Environment(Workspace.self) private var workspace
    private static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red]

    var body: some View {
        let plot = workspace.board.plot
        VStack(spacing: 0) {
            if plot.isEmpty {
                Text("Numbers printed by the board show up here — e.g. print(temp) or print(\"t=\", t, \"p=\", p).")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(plot.names, id: \.self) { name in
                        ForEach(plot.series[name] ?? [], id: \.index) { sample in
                            LineMark(x: .value("Sample", sample.index), y: .value(name, sample.value))
                                .foregroundStyle(by: .value("Series", name))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
                .chartForegroundStyleScale(domain: plot.names, range: Array(Self.palette.prefix(max(plot.names.count, 1))))
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis(.hidden)
                .padding(10)
            }
            Divider()
            HStack(spacing: 12) {
                ForEach(plot.names, id: \.self) { name in
                    if let last = plot.series[name]?.last {
                        Text("\(name): \(last.value, format: .number.precision(.fractionLength(0...3)))")
                            .font(.caption.monospacedDigit())
                    }
                }
                Spacer()
                Button { workspace.board.clearPlot() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Clear the plot")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}
