import Foundation

/// Installs micropython-lib packages the way `mpremote mip install` does: the Mac downloads the
/// files from micropython.org's index and copies them to the board's /lib (no Wi-Fi needed on the board).
public enum Mip {
    public static let index = URL(string: "https://micropython.org/pi/v2")!

    public struct File: Sendable, Equatable {
        /// Path on the board, e.g. `/lib/ssd1306.py`.
        public let path: String
        public let source: URL
        /// Leading hex digits of the file's SHA-256 (index packages), checked after download.
        public var hash: String? = nil

        /// Downloads the file, verifying it against the index hash.
        public func download(fetch: @Sendable (URL) async throws -> (Data, Int)) async throws -> Data {
            let (data, status) = try await fetch(source)
            guard status == 200 else { throw Error.download(source, status) }
            if let hash, !data.sha256Hex.hasPrefix(hash.lowercased()) { throw Error.corrupt(path) }
            return data
        }
    }

    public enum Error: LocalizedError {
        case notFound(String)
        case badIndex(String)
        case download(URL, Int)
        case corrupt(String)

        public var errorDescription: String? {
            switch self {
            case let .notFound(name): "No package named '\(name)' in micropython-lib"
            case let .badIndex(name): "Unexpected index entry for '\(name)'"
            case let .download(url, status): "Download failed (\(status)): \(url.absoluteString)"
            case let .corrupt(path): "Downloaded \(path) doesn't match the index hash"
            }
        }
    }

    /// Where a package's description lives. Plain names use the index; `github:user/repo/path.py`
    /// and `https://…/file.py` name a single file.
    public static func singleFileURL(_ spec: String) -> URL? {
        if spec.hasPrefix("github:") {
            let parts = spec.dropFirst("github:".count).split(separator: "/", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[2].hasSuffix(".py") else { return nil }
            return URL(string: "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/HEAD/\(parts[2])")
        }
        if (spec.hasPrefix("https://") || spec.hasPrefix("http://")) && spec.hasSuffix(".py") { return URL(string: spec) }
        return nil
    }

    public static func packageURL(_ name: String, version: String = "latest") -> URL {
        index.appendingPathComponent("package/py/\(name)/\(version).json")
    }

    /// Parses a package description into board files and dependencies.
    public static func parsePackage(_ data: Data, name: String, target: String = "/lib")
        throws -> (files: [File], deps: [(name: String, version: String)]) {
        guard case let .object(json)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw Error.badIndex(name)
        }
        var files: [File] = []
        for entry in json["hashes"]?.arrayValue ?? [] {
            guard let pair = entry.arrayValue, pair.count == 2,
                  let path = pair[0].stringValue, let hash = pair[1].stringValue, hash.count >= 2
            else { throw Error.badIndex(name) }
            files.append(File(path: target + "/" + path,
                              source: index.appendingPathComponent("file/\(hash.prefix(2))/\(hash)"), hash: hash))
        }
        let deps = (json["deps"]?.arrayValue ?? []).compactMap { entry -> (String, String)? in
            guard let pair = entry.arrayValue, let dep = pair.first?.stringValue else { return nil }
            return (dep, pair.count > 1 ? pair[1].stringValue ?? "latest" : "latest")
        }
        return (files, deps)
    }

    /// Resolves a package and its dependencies to files to copy.
    public static func resolve(_ spec: String, target: String = "/lib",
                               fetch: @Sendable (URL) async throws -> (Data, Int)) async throws -> [File] {
        if let url = singleFileURL(spec) {
            return [File(path: target + "/" + url.lastPathComponent, source: url)]
        }
        var files: [File] = []
        var seen = Set<String>()
        var queue: [(String, String)] = [(spec, "latest")]
        while let (name, version) = queue.first {
            queue.removeFirst()
            guard seen.insert(name).inserted else { continue }
            let (data, status) = try await fetch(packageURL(name, version: version))
            if status == 404 { throw Error.notFound(name) }
            guard status == 200 else { throw Error.download(packageURL(name, version: version), status) }
            let package = try parsePackage(data, name: name, target: target)
            files += package.files
            queue += package.deps
        }
        return files
    }

    /// Fetches with URLSession, returning the body and HTTP status.
    @Sendable public static func fetch(_ url: URL) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
