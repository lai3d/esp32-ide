import Foundation

/// Which project files go to the board.
public enum ProjectSync {
    /// MicroPython sources (and their data files) under `root`, skipping hidden folders,
    /// caches, virtualenvs and docs/tests that only matter on the Mac.
    public static let extensions: Set<String> = ["py", "mpy", "json"]
    public static let skippedFolders: Set<String> = ["docs", "tests", "test", "examples", "Examples"]

    public static func files(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if FileNode.ignoredNames.contains(name) || skippedFolders.contains(name)
                    || PythonEnvironment.venvNames.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if extensions.contains(url.pathExtension), !name.hasSuffix(".example.py") { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }
}
