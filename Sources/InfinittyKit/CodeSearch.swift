import Foundation

/// File-name search for the code view, powered by `rg --files` (fast, and it
/// respects .gitignore for free). The per-keystroke filtering happens in
/// memory against the cached file list — rg only runs once per root/refresh.
enum CodeSearch {

    static func ripgrepPath() -> String? {
        for path in ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Relative paths of candidate files under `root`. Calls back on the
    /// main queue. Falls back to a recursive FileManager walk when rg is
    /// unavailable (no .gitignore support in that case).
    static func listFiles(root: String, completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let files = listFilesSync(root: root)
            DispatchQueue.main.async { completion(files) }
        }
    }

    static func listFilesSync(root: String) -> [String] {
        if let rg = ripgrepPath(), let out = runRg(rg, root: root) {
            // rg prints absolute paths when given an absolute root; relativize.
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return out.split(separator: "\n").map { line in
                var s = String(line)
                if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
                return s
            }
        }
        return walk(root: root)
    }

    /// Case-insensitive substring match. Filename hits rank above
    /// path-only hits; result capped so huge repos stay snappy.
    static func filter(_ paths: [String], query: String, limit: Int = 200) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var nameHits: [String] = []
        var pathHits: [String] = []
        for p in paths {
            let lower = p.lowercased()
            if (p as NSString).lastPathComponent.lowercased().contains(q) {
                nameHits.append(p)
            } else if lower.contains(q) {
                pathHits.append(p)
            }
            if nameHits.count >= limit { break }
        }
        return Array((nameHits + pathHits).prefix(limit))
    }

    // MARK: - internals

    private static func runRg(_ rg: String, root: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rg)
        p.arguments = ["--files", "--color", "never", "--no-require-git", root]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard let _ = try? p.run() else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 || p.terminationStatus == 1 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func walk(root: String, limit: Int = 50_000) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            atPath: root) else { return [] }
        var out: [String] = []
        let rootURL = URL(fileURLWithPath: root)
        for case let path as String in enumerator {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent(path).path, isDirectory: &isDir)
            if isDir.boolValue {
                if path.hasPrefix(".git") { enumerator.skipDescendants() }
                continue
            }
            out.append(path)
            if out.count >= limit { break }
        }
        return out
    }
}
