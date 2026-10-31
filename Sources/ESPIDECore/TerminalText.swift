import Foundation

/// Turns raw REPL bytes into display text: CRLF → LF, backspaces erase, ANSI escape sequences
/// (the REPL's cursor moves and line clears) are dropped.
public enum TerminalText {
    public static func append(_ chunk: String, to text: inout String) {
        var escape = false
        for scalar in chunk.unicodeScalars {
            if escape {
                // CSI: ESC [ params… final byte in @…~
                if scalar != "[" && (0x40...0x7E).contains(scalar.value) { escape = false }
                continue
            }
            switch scalar {
            case "\u{1B}":
                escape = true
            case "\r":
                continue
            case "\u{08}":
                if let last = text.last, last != "\n" { text.removeLast() }
            case "\u{04}", "\u{07}":
                continue
            default:
                text.unicodeScalars.append(scalar)
            }
        }
    }
}
