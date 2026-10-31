import Foundation

/// Pulls numbers out of printed lines for the serial plotter.
///
/// `23.5` → one series; `23.5, 1011.7` or `23.5 1011.7` → series "1", "2";
/// `temp=23.5 hPa: 1011.7` → series named "temp" and "hPa".
public enum PlotParser {
    public static func values(in line: String) -> [(name: String, value: Double)] {
        let named = try! NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*[:=]\s*(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)"#)
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        let pairs = named.matches(in: line, range: range).compactMap { match -> (String, Double)? in
            Double(ns.substring(with: match.range(at: 2))).map { (ns.substring(with: match.range(at: 1)), $0) }
        }
        if !pairs.isEmpty { return pairs }
        // Only plot lines made of numbers, so tracebacks and log text don't add noise.
        let fields = line.split { $0 == "," || $0 == " " || $0 == "\t" || $0 == ";" }
        guard !fields.isEmpty, fields.count <= 8 else { return [] }
        var result: [(String, Double)] = []
        for (index, field) in fields.enumerated() {
            guard let value = Double(field), value.isFinite else { return [] }
            result.append((String(index + 1), value))
        }
        return result
    }
}

/// Recent values per series, fed with output text as it streams in.
public struct PlotData: Sendable {
    public struct Sample: Sendable, Hashable {
        public let index: Int
        public let value: Double
    }

    public private(set) var series: [String: [Sample]] = [:]
    /// Series names in the order they first appeared.
    public private(set) var names: [String] = []
    public var capacity = 500
    private var counter = 0
    private var partial = ""

    public init() {}

    public var isEmpty: Bool { series.isEmpty }

    /// Adds text; complete lines are parsed, a trailing partial line waits for more.
    public mutating func feed(_ text: String) {
        partial += text
        var lines = partial.components(separatedBy: "\n")
        partial = lines.removeLast()
        if partial.count > 1000 { partial = "" }
        for line in lines {
            let values = PlotParser.values(in: line.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !values.isEmpty else { continue }
            counter += 1
            for (name, value) in values {
                if series[name] == nil { names.append(name) }
                series[name, default: []].append(Sample(index: counter, value: value))
                if series[name]!.count > capacity { series[name]!.removeFirst(series[name]!.count - capacity) }
            }
        }
    }

    public mutating func clear() {
        self = PlotData()
    }
}
