import ESPIDECore
import SwiftUI

/// Rendered view of a Markdown file. Relative links open in the IDE; web links in the browser.
struct MarkdownPreview: View {
    @Environment(Workspace.self) private var workspace
    let text: String
    let fileURL: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Markdown.parse(text).enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == nil || url.isFileURL {
                let target = url.isFileURL ? url : URL(fileURLWithPath: url.path, relativeTo: fileURL.deletingLastPathComponent())
                workspace.openFile(target.standardizedFileURL)
                return .handled
            }
            return .systemAction
        })
    }

    @ViewBuilder
    private func view(for block: Markdown.Block) -> some View {
        switch block {
        case let .heading(level, text):
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.inline(text))
                    .font(Self.headingFont(level))
                    .padding(.top, level <= 2 ? 8 : 4)
                if level <= 2 { Divider() }
            }
        case let .paragraph(text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        case let .listItem(marker, depth, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 20)
        case let .code(_, text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        case let .table(header, alignments, rows):
            let widths = Self.columnWidths(header: header, rows: rows)
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow(alignment: .top) {
                        ForEach(header.indices, id: \.self) { column in
                            cell(header[column], width: widths[column], alignment: alignments[column]).fontWeight(.semibold)
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    ForEach(rows.indices, id: \.self) { row in
                        Divider()
                        GridRow(alignment: .top) {
                            ForEach(header.indices, id: \.self) { column in
                                cell(rows[row][column], width: widths[column], alignment: alignments[column])
                            }
                        }
                        .background(row.isMultiple(of: 2) ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            }
            // A horizontal scroll view doesn't size to its content's height on its own.
            .fixedSize(horizontal: false, vertical: true)
        case let .quote(text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: .separatorColor)).frame(width: 3)
                Text(Self.inline(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    /// A fixed width per column (inside a horizontal scroll view nothing else bounds them, and
    /// unbounded cells don't wrap): sized to the longest cell, CJK counted double, capped.
    static func columnWidths(header: [String], rows: [[String]]) -> [CGFloat] {
        func displayWidth(_ cell: String) -> Int {
            cell.unicodeScalars.reduce(0) { total, scalar in total + (scalar.value >= 0x2E80 ? 2 : 1) }
        }
        return header.indices.map { column in
            let cells: [String] = [header[column]] + rows.map { $0[column] }
            let longest: Int = cells.map(displayWidth).max() ?? 0
            return min(max(CGFloat(longest) * 7.6 + 24, 56), 380)
        }
    }

    private func cell(_ text: String, width: CGFloat, alignment: Markdown.Alignment) -> some View {
        Text(Self.inline(text))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: width, alignment: Self.frameAlignment(alignment))
            .gridColumnAlignment(Self.horizontal(alignment))
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .largeTitle.bold()
        case 2: .title.bold()
        case 3: .title2.bold()
        case 4: .title3.bold()
        default: .headline
        }
    }

    static func horizontal(_ alignment: Markdown.Alignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    static func frameAlignment(_ alignment: Markdown.Alignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
