import Foundation

/// Rewrites a MicroPython program so it can be paused, since the ESP32 firmware has no
/// `sys.settrace`. Every simple statement gets a probe in front of it, on the same line so
/// tracebacks keep their line numbers:
///
///     total += x            →    _K(7)and _P(7,lambda:total,lambda:x);total += x
///
/// `_K(line)` (cheap) decides whether to stop; only then does `_P` run, reading the function's
/// locals through the lambdas (MicroPython's `locals()` inside a function returns the globals);
/// their names are in `localNames`, once per function, to keep the program small.
/// Compound statement headers (`if`, `for`, `def`, …) aren't probed: a breakpoint there stops at
/// the next probed line. Functions compiled to native code (`@micropython.native`/`viper`/`asm_*`)
/// are left alone.
public enum PythonInstrumenter {
    public struct Result: Sendable, Equatable {
        public let code: String
        /// 1-based lines that have a probe, ascending.
        public let probeLines: [Int]
        /// Probed line → the function it is in ("f", "Class.method"); module-level lines are absent.
        public let functionOf: [Int: String]
        /// Lines after which the function may return (`return`, `raise`, its last statement).
        public let exitLines: Set<Int>
        /// Function → the local names its probes pass, in order.
        public let localNames: [String: [String]]

        /// Where a breakpoint on `line` actually stops: that line or the next probed one.
        public func probeLine(atOrAfter line: Int) -> Int? {
            probeLines.first { $0 >= line }
        }
    }

    private struct LogicalLine {
        let start: Int
        let end: Int
        let indent: Int
        let indentText: String
        /// Code with comments removed and string contents blanked, physical lines joined.
        let code: String
        var firstWord: String {
            let trimmed = code.drop { $0 == " " }
            if trimmed.first == "@" { return "@" }
            return String(trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        }
    }

    private final class Scope {
        let indent: Int
        let isFunction: Bool
        let qualname: String
        let skip: Bool
        var locals: Set<String> = []
        var declared: Set<String> = []
        var exitLines: Set<Int> = []
        var lastProbe: Int?

        init(indent: Int, isFunction: Bool, qualname: String, skip: Bool) {
            self.indent = indent
            self.isFunction = isFunction
            self.qualname = qualname
            self.skip = skip
        }
    }

    private static let compound: Set<String> = [
        "if", "elif", "else", "for", "while", "try", "except", "finally", "with", "def", "class", "async", "@", "match", "case",
    ]
    private static let notProbed: Set<String> = ["global", "nonlocal"]
    private static let nativeDecorator = try! NSRegularExpression(pattern: #"micropython\.(native|viper|asm_\w+)"#)
    private static let identifier = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*$"#)
    private static let walrus = try! NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*:="#)
    private static let asName = try! NSRegularExpression(pattern: #"\bas\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    private static let keywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
        "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal",
        "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
    ]

    public static func instrument(_ source: String) -> Result {
        let physical = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let logical = logicalLines(physical)

        // Pass 1: scopes, their local names, and which scope each line belongs to.
        let module = Scope(indent: -1, isFunction: false, qualname: "", skip: false)
        var stack = [module]
        var lineScopes: [(LogicalLine, Scope)] = []
        var decorators: [String] = []
        for line in logical {
            while stack.count > 1, line.indent <= stack.last!.indent { stack.removeLast() }
            let scope = stack.last!
            lineScopes.append((line, scope))
            let word = line.firstWord
            if word == "@" {
                decorators.append(line.code)
                continue
            }
            collectNames(line, into: scope)
            if scope.isFunction, ["return", "raise"].contains(word) { scope.exitLines.insert(line.start + 1) }
            if word == "def" || word == "class" || (word == "async" && line.code.contains("def ")) {
                let name = definedName(line.code) ?? "?"
                let native = decorators.contains { nativeDecorator.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
                let qualname = scope.qualname.isEmpty ? name : scope.qualname + "." + name
                let child = Scope(indent: line.indent, isFunction: word != "class", qualname: qualname, skip: scope.skip || native)
                if child.isFunction { child.locals.formUnion(parameters(line.code)) }
                stack.append(child)
            }
            decorators = []
        }

        // Pass 2: write the probes.
        var output = physical
        var probes: [Int] = []
        var functionOf: [Int: String] = [:]
        var localNames: [String: [String]] = [:]
        for (line, scope) in lineScopes {
            let word = line.firstWord
            guard !scope.skip, !compound.contains(word), !notProbed.contains(word), !isFutureImport(line.code),
                  !isDocstring(line.code) else { continue }
            let number = line.start + 1
            var probe = "_K(\(number))and _P(\(number)"
            if scope.isFunction {
                let names = scope.locals.subtracting(scope.declared).sorted()
                for name in names { probe += ",lambda:\(name)" }
                localNames[scope.qualname] = names
                functionOf[number] = scope.qualname
                scope.lastProbe = number
            }
            probe += ");"
            let text = physical[line.start]
            output[line.start] = line.indentText + probe + text.dropFirst(line.indentText.count)
            probes.append(number)
        }
        var exits: Set<Int> = []
        for (_, scope) in lineScopes where scope.isFunction && !scope.skip {
            exits.formUnion(scope.exitLines)
            if let last = scope.lastProbe { exits.insert(last) }
        }
        return Result(code: output.joined(separator: "\n"), probeLines: probes, functionOf: functionOf, exitLines: exits,
                      localNames: localNames)
    }

    /// A statement that is only a string (a docstring) does nothing worth stopping on.
    private static func isDocstring(_ code: String) -> Bool {
        let trimmed = code.drop { $0 == " " }.drop { "rRbBuUfF".contains($0) }
        return trimmed.first == "\"" || trimmed.first == "'"
    }

    private static func isFutureImport(_ code: String) -> Bool {
        code.trimmingCharacters(in: .whitespaces).hasPrefix("from __future__")
    }

    // MARK: - Lexing

    /// Splits source into logical lines (joining bracketed and backslash-continued lines),
    /// skipping blank and comment-only lines.
    private static func logicalLines(_ lines: [String]) -> [LogicalLine] {
        var result: [LogicalLine] = []
        var depth = 0
        var quote: Character?
        var triple = false
        var start: Int?
        var code = ""
        for (index, line) in lines.enumerated() {
            var masked = ""
            var chars = Array(line)
            var i = 0
            var continued = false
            while i < chars.count {
                let c = chars[i]
                if let q = quote {
                    if c == "\\" {
                        masked += "  "
                        i += 2
                        continue
                    }
                    if c == q, !triple || (i + 2 < chars.count && chars[i + 1] == q && chars[i + 2] == q) {
                        masked += triple ? String(repeating: q, count: 3) : String(q)
                        i += triple ? 3 : 1
                        quote = nil
                        continue
                    }
                    masked += " "
                    i += 1
                    continue
                }
                if c == "#" { break }
                if c == "'" || c == "\"" {
                    quote = c
                    triple = i + 2 < chars.count && chars[i + 1] == c && chars[i + 2] == c
                    masked += triple ? String(repeating: c, count: 3) : String(c)
                    i += triple ? 3 : 1
                    continue
                }
                if "([{".contains(c) { depth += 1 }
                if ")]}".contains(c) { depth = max(0, depth - 1) }
                if c == "\\" && i == chars.count - 1 {
                    continued = true
                    break
                }
                masked.append(c)
                i += 1
            }
            // An unterminated single-quoted string ends at the line end (a syntax error anyway).
            if quote != nil && !triple { quote = nil }
            if start == nil {
                guard !masked.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                start = index
                code = masked
            } else {
                code += " " + masked
            }
            if depth == 0 && quote == nil && !continued, let first = start {
                let indentText = String(lines[first].prefix { $0 == " " || $0 == "\t" })
                let width = indentText.reduce(0) { $0 + ($1 == "\t" ? 8 : 1) }
                result.append(LogicalLine(start: first, end: index, indent: width, indentText: indentText, code: code))
                start = nil
                code = ""
            }
            chars = []
        }
        return result
    }

    // MARK: - Names

    private static func isIdentifier(_ text: String) -> Bool {
        identifier.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil && !keywords.contains(text)
    }

    /// `def name(` / `class Name` → the name.
    private static func definedName(_ code: String) -> String? {
        let words = code.split(whereSeparator: { " (:".contains($0) })
        guard let index = words.firstIndex(where: { $0 == "def" || $0 == "class" }), index + 1 < words.count else { return nil }
        return String(words[index + 1])
    }

    /// Parameter names of a `def` header.
    private static func parameters(_ code: String) -> Set<String> {
        guard let open = code.firstIndex(of: "(") else { return [] }
        var depth = 0
        var close = code.endIndex
        for index in code[open...].indices {
            if "([{".contains(code[index]) { depth += 1 }
            if ")]}".contains(code[index]) {
                depth -= 1
                if depth == 0 { close = index; break }
            }
        }
        let inside = String(code[code.index(after: open)..<close])
        return Set(splitTopLevel(inside, on: ",").compactMap { part in
            var name = part.trimmingCharacters(in: .whitespaces)
            while name.hasPrefix("*") { name.removeFirst() }
            name = String(name.prefix { $0 != ":" && $0 != "=" }).trimmingCharacters(in: .whitespaces)
            return isIdentifier(name) ? name : nil
        })
    }

    /// Adds the names a statement binds (or declares global) to its scope.
    private static func collectNames(_ line: LogicalLine, into scope: Scope) {
        let code = line.code.trimmingCharacters(in: .whitespaces)
        let word = line.firstWord
        let range = NSRange(code.startIndex..., in: code)
        for match in walrus.matches(in: code, range: range) {
            scope.locals.insert((code as NSString).substring(with: match.range(at: 1)))
        }
        switch word {
        case "global", "nonlocal":
            for name in code.dropFirst(word.count).split(separator: ",") {
                scope.declared.insert(name.trimmingCharacters(in: .whitespaces))
            }
        case "def", "class", "async":
            if let name = definedName(code) { scope.locals.insert(name) }
        case "import":
            for part in code.dropFirst(6).split(separator: ",") {
                let words = part.split(separator: " ")
                if let alias = words.last, words.count >= 3, words[words.count - 2] == "as" { scope.locals.insert(String(alias)) }
                else if let module = words.first?.split(separator: ".").first { scope.locals.insert(String(module)) }
            }
        case "from":
            guard let importRange = code.range(of: " import ") else { return }
            let names = code[importRange.upperBound...].replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            for part in names.split(separator: ",") {
                let words = part.split(separator: " ")
                if let name = words.last, isIdentifier(String(name)) { scope.locals.insert(String(name)) }
            }
        case "for":
            let afterFor = code.dropFirst(3)
            if let inRange = afterFor.range(of: " in ") { addTargets(String(afterFor[..<inRange.lowerBound]), to: scope) }
        case "with", "except":
            for match in asName.matches(in: code, range: range) {
                scope.locals.insert((code as NSString).substring(with: match.range(at: 1)))
            }
        default:
            guard !compound.contains(word) else { return }
            let parts = splitAssignments(code)
            for target in parts.dropLast() { addTargets(target, to: scope) }
        }
    }

    /// `a, (b, *c)` → a, b, c; attribute and subscript targets bind nothing.
    private static func addTargets(_ text: String, to scope: Scope) {
        var target = text.trimmingCharacters(in: .whitespaces)
        if let colon = target.firstIndex(of: ":"), !target.hasPrefix("(") { target = String(target[..<colon]) }
        for part in splitTopLevel(target, on: ",") {
            var name = part.trimmingCharacters(in: .whitespaces)
            while name.hasPrefix("*") { name.removeFirst() }
            if (name.hasPrefix("(") && name.hasSuffix(")")) || (name.hasPrefix("[") && name.hasSuffix("]")) {
                addTargets(String(name.dropFirst().dropLast()), to: scope)
            } else if isIdentifier(name) {
                scope.locals.insert(name)
            }
        }
    }

    /// `a = b = f(x=1)` → ["a ", " b ", " f(x=1)"]; `n += 1` → ["n ", " 1"]. Comparisons don't split.
    static func splitAssignments(_ code: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        let chars = Array(code)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if "([{".contains(c) { depth += 1 }
            if ")]}".contains(c) { depth -= 1 }
            if c == "=", depth == 0 {
                let previous = i > 0 ? chars[i - 1] : " "
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if next == "=" {
                    current += "=="
                    i += 2
                    continue
                }
                if "=!<>:".contains(previous) && !(previous == ">" && i > 1 && chars[i - 2] == ">")
                    && !(previous == "<" && i > 1 && chars[i - 2] == "<") {
                    current.append(c)
                    i += 1
                    continue
                }
                // Augmented assignment: drop the operator from the target.
                while let last = current.last, "+-*/%&|^@<>".contains(last) { current.removeLast() }
                parts.append(current)
                current = ""
                i += 1
                continue
            }
            if c == "l", depth == 0, String(chars[i...].prefix(7)) == "lambda " || String(chars[i...].prefix(7)) == "lambda:" {
                // `f = lambda x=1: x`: nothing after `lambda` is a target.
                current += String(chars[i...])
                break
            }
            current.append(c)
            i += 1
        }
        parts.append(current)
        return parts
    }

    private static func splitTopLevel(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for c in text {
            if "([{".contains(c) { depth += 1 }
            if ")]}".contains(c) { depth -= 1 }
            if c == separator, depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }
}
