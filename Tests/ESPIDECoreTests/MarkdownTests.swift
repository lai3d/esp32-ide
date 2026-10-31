import Foundation
import Testing
@testable import ESPIDECore

@Suite struct MarkdownTests {
    @Test func parsesBlocks() {
        let blocks = Markdown.parse("""
        # Title ##
        Some *text*
        continues here.

        - one
          more of one
          - nested
        1. first
        - [x] done

        > quoted
        > lines

        ---
        ```sh
        uvx mpremote ls
        ```
        """)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some *text* continues here."),
            .listItem(marker: "•", depth: 0, text: "one more of one"),
            .listItem(marker: "•", depth: 1, text: "nested"),
            .listItem(marker: "1.", depth: 0, text: "first"),
            .listItem(marker: "•", depth: 0, text: "☑ done"),
            .quote("quoted lines"),
            .rule,
            .code(language: "sh", text: "uvx mpremote ls"),
        ])
    }

    @Test func parsesTables() {
        let blocks = Markdown.parse("""
        | 模块 | 地址 | 说明 |
        |---|:---:|--:|
        | LCD1602 | `0x27` | a \\| b |
        | OLED | 0x3C |
        after
        """)
        #expect(blocks == [
            .table(header: ["模块", "地址", "说明"], alignments: [.leading, .center, .trailing],
                   rows: [["LCD1602", "`0x27`", "a | b"], ["OLED", "0x3C", ""]]),
            .paragraph("after"),
        ])
    }

    @Test func pipeInParagraphIsNotATable() {
        #expect(Markdown.parse("a | b\nnot a delimiter") == [.paragraph("a | b not a delimiter")])
    }

    @Test func parsesTheProjectDocs() throws {
        let url = URL(fileURLWithPath: "/Users/larry/develop/esp32/esp32-clock/docs/hardware-notes.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let blocks = Markdown.parse(text)
        #expect(blocks.contains { if case .table = $0 { true } else { false } })
        #expect(blocks.first == .heading(level: 1, text: "硬件调研笔记"))
    }

    @Test func highlightsSource() {
        let text = "## Wiring\n- **G16** → `CLK`\n| a | b |\n|---|---|\n[link](docs/x.md)\n```\ncode | here\n```"
        let ns = text as NSString
        let tokens = MarkdownHighlighter.tokenize(text).map { (ns.substring(with: $0.range), $0.kind) }
        #expect(tokens.contains { $0 == ("## Wiring", .keyword) })
        #expect(tokens.contains { $0 == ("**G16**", .type) })
        #expect(tokens.contains { $0 == ("`CLK`", .string) })
        #expect(tokens.contains { $0 == ("[link](docs/x.md)", .function) })
        #expect(tokens.contains { $0.0.hasPrefix("|---") && $0.1 == .comment })
        #expect(tokens.contains { $0.0.contains("code | here") && $0.1 == .string })
        #expect(tokens.contains { $0 == ("-", .decorator) })
    }
}
