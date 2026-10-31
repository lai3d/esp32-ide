import Foundation

/// A file or folder on the board's flash filesystem.
public struct DeviceFile: Identifiable, Hashable, Sendable {
    public let path: String
    public let isDirectory: Bool
    public let size: Int
    public var children: [DeviceFile]?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, isDirectory: Bool, size: Int, children: [DeviceFile]? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
    }
}

/// File operations on the board, done by running small MicroPython snippets in the raw REPL.
public enum DeviceFiles {
    /// Bytes of file content per `exec` when writing or reading.
    static let transferChunk = 1024

    public static let listScript = """
    import os
    def _w(p):
        for e in os.ilistdir(p):
            f = (p if p != '/' else '') + '/' + e[0]
            if e[1] & 0x4000:
                print('D', 0, f)
                _w(f)
            else:
                print('F', e[3] if len(e) > 3 else 0, f)
    _w('/')
    del _w
    """

    /// Parses `listScript` output into a tree sorted folders-first.
    public static func parseListing(_ output: String) -> [DeviceFile] {
        var flat: [DeviceFile] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count == 3, let size = Int(parts[1]) else { continue }
            flat.append(DeviceFile(path: String(parts[2]), isDirectory: parts[0] == "D", size: size))
        }
        return tree(flat, parent: "")
    }

    private static func tree(_ flat: [DeviceFile], parent: String) -> [DeviceFile] {
        flat.filter { ($0.path as NSString).deletingLastPathComponent == (parent.isEmpty ? "/" : parent) }
            .map { file in
                var file = file
                if file.isDirectory { file.children = tree(flat, parent: file.path) }
                return file
            }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    /// A Python string literal for a path.
    static func literal(_ string: String) -> String {
        var out = "'"
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "'"
    }

    /// A Python bytes literal, printable ASCII kept as-is (smaller than hex for source files).
    static func bytesLiteral(_ data: Data) -> String {
        var out = "b'"
        for byte in data {
            switch byte {
            case 0x5C: out += "\\\\"
            case 0x27: out += "\\'"
            case 0x0A: out += "\\n"
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(byte))
            default: out += String(format: "\\x%02x", byte)
            }
        }
        return out + "'"
    }

    /// Code that creates every missing parent folder of `path`.
    static func makeParentsScript(_ path: String) -> String? {
        let parents = (path as NSString).deletingLastPathComponent
        guard parents != "/" && !parents.isEmpty else { return nil }
        return """
        import os
        p = ''
        for d in \(literal(parents)).split('/')[1:]:
            p += '/' + d
            try:
                os.mkdir(p)
            except OSError:
                pass
        """
    }

    /// Code computing SHA-256 of each path ("-" when missing), one line per path.
    public static func hashScript(_ paths: [String]) -> String {
        """
        import hashlib, binascii
        for p in [\(paths.map(literal).joined(separator: ", "))]:
            try:
                h = hashlib.sha256()
                with open(p, 'rb') as f:
                    while True:
                        b = f.read(512)
                        if not b:
                            break
                        h.update(b)
                print(binascii.hexlify(h.digest()).decode())
            except OSError:
                print('-')
        """
    }
}

extension MicroPythonDevice.RawSession {
    public func listFiles() async throws -> [DeviceFile] {
        DeviceFiles.parseListing(try await exec(DeviceFiles.listScript, timeout: .seconds(20)))
    }

    public func writeFile(_ path: String, contents: Data) async throws {
        if let mkdirs = DeviceFiles.makeParentsScript(path) { _ = try await exec(mkdirs) }
        _ = try await exec("_f = open(\(DeviceFiles.literal(path)), 'wb')")
        var offset = 0
        while offset < contents.count {
            let end = min(offset + DeviceFiles.transferChunk, contents.count)
            _ = try await exec("_f.write(\(DeviceFiles.bytesLiteral(contents.subdata(in: offset..<end))))")
            offset = end
        }
        _ = try await exec("_f.close()\ndel _f")
    }

    public func readFile(_ path: String) async throws -> Data {
        let output = try await exec("""
            import binascii
            with open(\(DeviceFiles.literal(path)), 'rb') as f:
                while True:
                    b = f.read(\(DeviceFiles.transferChunk))
                    if not b:
                        break
                    print(binascii.hexlify(b).decode())
            """, timeout: .seconds(60))
        var data = Data()
        for line in output.split(whereSeparator: \.isNewline) {
            guard let chunk = Data(hex: String(line)) else {
                throw DeviceError.protocolError("bad file data")
            }
            data.append(chunk)
        }
        return data
    }

    /// Deletes a file, or a folder with everything in it.
    public func remove(_ path: String) async throws {
        _ = try await exec("""
            import os
            def _rm(p):
                if os.stat(p)[0] & 0x4000:
                    for e in os.ilistdir(p):
                        _rm(p + '/' + e[0])
                    os.rmdir(p)
                else:
                    os.remove(p)
            _rm(\(DeviceFiles.literal(path)))
            del _rm
            """)
    }

    public func makeDirectory(_ path: String) async throws {
        _ = try await exec("import os\nos.mkdir(\(DeviceFiles.literal(path)))")
    }

    /// SHA-256 hex digests of files on the board, nil for missing ones.
    public func hashes(of paths: [String]) async throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let lines = try await exec(DeviceFiles.hashScript(paths), timeout: .seconds(30))
            .split(whereSeparator: \.isNewline).map(String.init)
        var result: [String: String] = [:]
        for (path, line) in zip(paths, lines) where line != "-" { result[path] = line }
        return result
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

import CryptoKit

extension Data {
    /// Lowercase hex SHA-256, comparable with the board's `hashlib.sha256`.
    public var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
