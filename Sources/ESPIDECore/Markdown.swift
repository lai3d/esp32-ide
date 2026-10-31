import Foundation

/// A small block-level Markdown parser for the preview (CommonMark subset plus GFM tables).
/// Inline formatting (bold, code, links) is left to `AttributedString(markdown:)`.
public enum Markdown {
    public enum Alignment: Sendable, Equatable {
        case leading, center, trailing
    }

    public enum Block: Sendable, Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        /// `marker` is "•" or "3." for ordered items; `depth` counts nesting from 0.
        case listItem(marker: String, depth: Int, text: String)
        case code(language: String?, text: String)
        case table(header: [String], alignments: [Alignment], rows: [[String]])
        case quote(String)
        case rule
    }

    public static func parse(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var index = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))) }
            paragraph = []
            quote = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if let (level, text) = heading(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: text))
                continue
            }
            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                flush()
                blocks.append(item)
                continue
            }
            // A table: a row of cells followed by a delimiter row such as |---|:--:|
            if trimmed.contains("|"), index + 1 < lines.count, let alignments = delimiterRow(lines[index + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    var cells = cells(row)
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(header.count)))
                    index += 1
                }
                index -= 1  // the defer moves past the last row
                let aligned = alignments.count >= header.count ? Array(alignments.prefix(header.count))
                    : alignments + Array(repeating: .leading, count: header.count - alignments.count)
                blocks.append(.table(header: header, alignments: aligned, rows: rows))
                continue
            }
            if !quote.isEmpty {
                // A lazy continuation line of a quote.
                quote.append(trimmed)
                continue
            }
            // An indented line right after a list item continues it.
            if case let .listItem(marker, depth, text)? = blocks.last, paragraph.isEmpty, line.first == " " {
                blocks[blocks.count - 1] = .listItem(marker: marker, depth: depth, text: text + " " + trimmed)
                continue
            }
            paragraph.append(trimmed)
        }
        flush()
        return blocks
    }

    static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }  // closing hashes: "## Title ##"
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func listItem(_ line: String) -> Block? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        let depth = indent / 2
        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            var text = String(body.dropFirst(2))
            // Task lists: "- [ ] todo" / "- [x] done"
            if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) }
            else if text.lowercased().hasPrefix("[x] ") { text = "☑ " + text.dropFirst(4) }
            return .listItem(marker: "•", depth: depth, text: text)
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let after = body.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return .listItem(marker: "\(digits).", depth: depth, text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    /// Splits `| a | b |` into cells; `\|` stays a literal pipe.
    static func cells(_ row: String) -> [String] {
        var line = row.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("|") { line.removeFirst() }
        if line.hasSuffix("|") && !line.hasSuffix("\\|") { line.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for char in line {
            if escaped {
                current.append(char == "|" ? "|" : "\\\(char)")
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "`" {
                inCode.toggle()
                current.append(char)
            } else if char == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func delimiterRow(_ line: String) -> [Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-") else { return nil }
        var result: [Alignment] = []
        for cell in cells(trimmed) {
            guard !cell.isEmpty, cell.allSatisfy({ $0 == "-" || $0 == ":" }), cell.contains("-") else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.trailing)
            default: result.append(.leading)
            }
        }
        return result
    }

    public static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }
}

/// Coloring for Markdown source in the editor (same token kinds as the code highlighters).
public enum MarkdownHighlighter {
    private static let regex = try! NSRegularExpression(pattern: [
        #"((?:^|\n)(?:```|~~~)[^\n]*\n[\s\S]*?(?:\n(?:```|~~~)[^\n]*|$(?![\s\S])))"#, // 1: fenced code block
        #"((?:^|(?<=\n))#{1,6}[ \t][^\n]*)"#,                                        // 2: heading
        #"(`[^`\n]+`)"#,                                                             // 3: inline code
        #"(!?\[[^\]\n]*\]\([^)\n]*\))"#,                                             // 4: link / image
        #"(\*\*[^*\n]+\*\*|__[^_\n]+__)"#,                                           // 5: bold
        #"((?:^|(?<=\n))[ \t]*(?:[-*+]|\d{1,9}[.)])(?=[ \t]))"#,                      // 6: list marker
        #"((?:^|(?<=\n))[ \t]*>[^\n]*)"#,                                            // 7: blockquote
        #"((?:^|(?<=\n))[ \t]*\|?[ \t]*:?-{3,}:?[ \t]*(?:\|[ \t]*:?-{3,}:?[ \t]*)*\|?[ \t]*(?=\n|$))"#, // 8: table delimiter
        #"(\|)"#,                                                                    // 9: table pipe
    ].joined(separator: "|"))

    public static func tokenize(_ text: String) -> [PyToken] {
        let ns = text as NSString
        let kinds: [PyTokenKind] = [.string, .keyword, .string, .function, .type, .decorator, .comment, .comment, .comment]
        var tokens: [PyToken] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for group in 1...kinds.count where match.range(at: group).location != NSNotFound {
                tokens.append(PyToken(range: match.range(at: group), kind: kinds[group - 1]))
                break
            }
        }
        return tokens
    }
}
