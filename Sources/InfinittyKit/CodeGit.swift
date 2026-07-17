import Foundation

/// One entry from `git status --porcelain=v1`: staged (x) and worktree (y)
/// status letters plus the repo-relative path (for renames, the new path).
/// Hashable because NSOutlineView hashes its items (Equatable-only structs
/// fall back to the slow ObjC `-hash` bridge and trigger a runtime warning).
struct CodeChange: Hashable {
    let x: Character
    let y: Character
    let path: String

    /// Short display label: "M", "A", "D", "R", "??", ...
    var label: String {
        if x == "?" && y == "?" { return "??" }
        if x != " " { return String(x) }
        return String(y)
    }

    var isStaged: Bool { x != " " && x != "?" }
    var isUntracked: Bool { x == "?" && y == "?" }
}

/// Thin wrapper over the git CLI for the code-view Changes tab. All calls
/// are synchronous — invoke from a background queue.
enum CodeGit {

    /// Repo root containing `dir`, or nil when not inside a work tree.
    static func repoRoot(of dir: String) -> String? {
        run(["-C", dir, "rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    /// Result of a `git status` probe: branch + changes, or git's stderr
    /// when the call itself failed (still inside a repo — read operations
    /// can fail too, e.g. a corrupt index).
    struct RepoStatus {
        let branch: String?
        let changes: [CodeChange]
        let error: String?
    }

    /// Branch name + changes for `repo` (a root from `repoRoot`). Never nil:
    /// failures arrive in `error` instead of masquerading as a clean tree.
    static func status(in repo: String) -> RepoStatus {
        let result = runDetailed(["-C", repo, "status", "--porcelain=v1", "-b"])
        guard result.status == 0 else {
            return RepoStatus(branch: nil, changes: [], error: result.stderr)
        }
        let (branch, changes) = parseStatus(result.stdout)
        return RepoStatus(branch: branch, changes: changes, error: nil)
    }

    /// The diff to preview for a change. Staged and unstaged sections are
    /// concatenated when both exist; untracked files return no text (the
    /// caller previews the file contents instead). `error` carries git's
    /// stderr when every diff attempt failed.
    static func diff(in repo: String, for change: CodeChange) -> (text: String?, error: String?) {
        var parts: [String] = []
        var firstError: String?
        if change.isStaged {
            let staged = runDetailed(["-C", repo, "diff", "--no-color", "--cached", "--", change.path])
            if staged.status == 0, !staged.stdout.isEmpty { parts.append(staged.stdout) }
            else if staged.status != 0, firstError == nil { firstError = staged.stderr }
        }
        if !change.isUntracked, change.y != " " {
            let unstaged = runDetailed(["-C", repo, "diff", "--no-color", "--", change.path])
            if unstaged.status == 0, !unstaged.stdout.isEmpty {
                if !parts.isEmpty { parts.append("--- unstaged ---\n") }
                parts.append(unstaged.stdout)
            } else if unstaged.status != 0, firstError == nil {
                firstError = unstaged.stderr
            }
        }
        return (parts.isEmpty ? nil : parts.joined(), parts.isEmpty ? firstError : nil)
    }

    /// Local branch names for `repo`.
    static func branches(in repo: String) -> [String] {
        (run(["-C", repo, "branch", "--format=%(refname:short)"]) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// Switch `repo` to `branch`. nil on success; git's stderr on failure
    /// (e.g. uncommitted changes that would be overwritten).
    static func checkout(in repo: String, branch: String) -> String? {
        let result = runDetailed(["-C", repo, "checkout", branch])
        return result.status == 0
            ? nil
            : (result.stderr.isEmpty ? "git checkout failed" : result.stderr)
    }

    /// Stage one path (untracked, modified or deleted). nil on success;
    /// git's stderr on failure (e.g. a stale index.lock).
    static func stage(in repo: String, path: String) -> String? {
        let result = runDetailed(["-C", repo, "add", "--", path])
        return result.status == 0 ? nil : result.stderr
    }

    /// Unstage one path (`git restore --staged`, falling back to `git reset`).
    /// nil on success; git's stderr on failure.
    static func unstage(in repo: String, path: String) -> String? {
        let restored = runDetailed(["-C", repo, "restore", "--staged", "--", path])
        if restored.status == 0 { return nil }
        let reset = runDetailed(["-C", repo, "reset", "-q", "HEAD", "--", path])
        return reset.status == 0 ? nil : reset.stderr
    }

    /// Stage every change in the worktree. nil on success; stderr on failure.
    static func stageAll(in repo: String) -> String? {
        let result = runDetailed(["-C", repo, "add", "-A"])
        return result.status == 0 ? nil : result.stderr
    }

    /// Commit the staged changes with `message`. nil on success; git's
    /// stderr on failure (nothing staged, no identity configured, hook).
    static func commit(in repo: String, message: String) -> String? {
        let result = runDetailed(["-C", repo, "commit", "-m", message])
        return result.status == 0 ? nil : result.stderr
    }

    // MARK: - parsing (pure, unit-tested)

    static func parseStatus(_ output: String) -> (branch: String?, changes: [CodeChange]) {
        var branch: String?
        var changes: [CodeChange] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                branch = parseBranch(String(line.dropFirst(3)))
                continue
            }
            guard line.count > 3 else { continue }
            let x = line[line.startIndex]
            let y = line[line.index(after: line.startIndex)]
            var path = String(line.dropFirst(3))
            // Renames/copies: "old -> new" — show the new path.
            if let arrow = path.range(of: " -> ", options: .backwards) {
                path = String(path[arrow.upperBound...])
            }
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count > 1 {
                path = String(path.dropFirst().dropLast())
            }
            guard !path.isEmpty else { continue }
            changes.append(CodeChange(x: x, y: y, path: path))
        }
        return (branch, changes)
    }

    /// "## main...origin/main" → "main"; "## No commits yet on main" → "main";
    /// detached → nil.
    private static func parseBranch(_ s: String) -> String? {
        if s.hasPrefix("HEAD") { return nil }
        if let range = s.range(of: "No commits yet on ") {
            return String(s[range.upperBound...])
        }
        if let dots = s.range(of: "...") {
            return String(s[s.startIndex..<dots.lowerBound])
        }
        return s.nilIfEmpty
    }

    // MARK: - process

    private static func run(_ args: [String]) -> String? {
        let result = runDetailed(args)
        guard result.status == 0 else { return nil }
        return result.stdout
    }

    private static func runDetailed(
        _ args: [String]
    ) -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard let _ = try? p.run() else { return (-1, "", "could not launch git") }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (
            p.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
