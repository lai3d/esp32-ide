import Foundation

/// A regex-based C/C++ lexer for ESP-IDF sources (same token kinds as the Python highlighter).
public enum CHighlighter {
    public static let keywords: Set<String> = [
        "auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto",
        "if", "inline", "register", "restrict", "return", "sizeof", "static", "struct", "switch", "typedef",
        "union", "volatile", "while", "_Static_assert", "static_assert",
        "class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "override",
        "new", "delete", "this", "using", "constexpr", "nullptr", "true", "false", "NULL", "try", "catch", "throw",
    ]

    public static let types: Set<String> = [
        "void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool", "size_t",
        "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
        "esp_err_t", "TaskHandle_t", "QueueHandle_t", "SemaphoreHandle_t", "TickType_t", "BaseType_t", "gpio_num_t",
    ]

    private static let regex = try! NSRegularExpression(pattern: [
        #"(//[^\n]*|/\*[\s\S]*?(?:\*/|$(?![\s\S])))"#,                    // 1: comment
        #"("(?:\\.|[^"\\\n])*"?|'(?:\\.|[^'\\\n])*'?)"#,                  // 2: string / char
        #"((?:(?<=\n)|^)[ \t]*#[ \t]*[a-z]+)"#,                            // 3: preprocessor
        #"((?<![\w])(?:0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?)[uUlLfF]*)"#, // 4: number
        #"([A-Za-z_]\w*)(\s*\()?"#,                                        // 5: identifier, 6: call
    ].joined(separator: "|"))

    public static func tokenize(_ text: String) -> [PyToken] {
        let ns = text as NSString
        var tokens: [PyToken] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range(at: 1).location != NSNotFound {
                tokens.append(PyToken(range: match.range(at: 1), kind: .comment))
            } else if match.range(at: 2).location != NSNotFound {
                tokens.append(PyToken(range: match.range(at: 2), kind: .string))
            } else if match.range(at: 3).location != NSNotFound {
                tokens.append(PyToken(range: match.range(at: 3), kind: .decorator))
            } else if match.range(at: 4).location != NSNotFound {
                tokens.append(PyToken(range: match.range(at: 4), kind: .number))
            } else if match.range(at: 5).location != NSNotFound {
                let word = ns.substring(with: match.range(at: 5))
                if keywords.contains(word) {
                    tokens.append(PyToken(range: match.range(at: 5), kind: .keyword))
                } else if types.contains(word) {
                    tokens.append(PyToken(range: match.range(at: 5), kind: .type))
                } else if match.range(at: 6).location != NSNotFound {
                    tokens.append(PyToken(range: match.range(at: 5), kind: .function))
                }
            }
        }
        return tokens
    }

    public static func isCSource(_ url: URL) -> Bool {
        ["c", "h", "cpp", "cc", "cxx", "hpp", "hh", "ino"].contains(url.pathExtension.lowercased())
    }
}
