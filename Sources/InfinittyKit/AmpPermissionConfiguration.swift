import Foundation

/// Builds a private, per-turn Amp settings overlay that preserves the user's
/// settings while placing Infinitty's scoped permission delegate first.
enum AmpPermissionConfiguration {
    enum ConfigurationError: LocalizedError {
        case unreadableSettings(String)
        case invalidSettings(String)
        case couldNotWrite

        var errorDescription: String? {
            switch self {
            case .unreadableSettings(let path):
                return "Amp settings could not be read at \(path)."
            case .invalidSettings(let path):
                return "Amp settings at \(path) are not valid JSON or JSONC."
            case .couldNotWrite:
                return "Infinitty could not create Amp's scoped permission settings."
            }
        }
    }

    static func mergedSettings(
        existing: Data?,
        helperPath: String
    ) -> Data? {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let parsed = settingsObject(from: existing) else { return nil }
            root = parsed
        }

        var permissions: [[String: Any]]
        if let raw = root["amp.permissions"] {
            guard let parsed = raw as? [[String: Any]] else { return nil }
            permissions = parsed
        } else {
            permissions = []
        }
        permissions.removeAll { entry in
            entry["tool"] as? String == "*"
                && entry["action"] as? String == "delegate"
                && entry["to"] as? String == helperPath
        }
        permissions.insert([
            "tool": "*",
            "action": "delegate",
            "to": helperPath,
        ], at: 0)
        root["amp.permissions"] = permissions
        root["amp.dangerouslyAllowAll"] = false

        return try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func writeTemporarySettings(
        helperPath: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let sourceURL = userSettingsURL(
            fileManager: fileManager, environment: environment)
        let existing: Data?
        if let sourceURL {
            guard let data = try? Data(contentsOf: sourceURL) else {
                throw ConfigurationError.unreadableSettings(sourceURL.path)
            }
            existing = data
        } else {
            existing = nil
        }
        guard let data = mergedSettings(
            existing: existing, helperPath: helperPath) else {
            throw ConfigurationError.invalidSettings(
                sourceURL?.path ?? "the configured location")
        }

        let url = fileManager.temporaryDirectory.appendingPathComponent(
            "infinitty-amp-permissions-\(UUID().uuidString.lowercased()).json")
        guard fileManager.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]) else {
            throw ConfigurationError.couldNotWrite
        }
        return url
    }

    static func userSettingsURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let explicit = environment["AMP_SETTINGS_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            let expanded = NSString(string: explicit).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        let home = environment["HOME"]
            ?? fileManager.homeDirectoryForCurrentUser.path
        let directory = URL(fileURLWithPath: home)
            .appendingPathComponent(".config/amp", isDirectory: true)
        for name in ["settings.json", "settings.jsonc"] {
            let candidate = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func settingsObject(from data: Data) -> [String: Any]? {
        if let direct = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] {
            return direct
        }
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let sanitized = removingTrailingCommas(from: removingComments(from: text))
        return try? JSONSerialization.jsonObject(with: Data(sanitized.utf8))
            as? [String: Any]
    }

    private static func removingComments(from text: String) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0
        var inString = false
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                index += 1
                continue
            }
            if character == "/", index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "/" {
                    index += 2
                    while index < characters.count,
                          !characters[index].isNewline {
                        index += 1
                    }
                    continue
                }
                if next == "*" {
                    index += 2
                    while index + 1 < characters.count,
                          !(characters[index] == "*"
                            && characters[index + 1] == "/") {
                        if characters[index].isNewline { output.append("\n") }
                        index += 1
                    }
                    index = min(index + 2, characters.count)
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output
    }

    private static func removingTrailingCommas(from text: String) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0
        var inString = false
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                index += 1
                continue
            }
            if character == "," {
                var lookahead = index + 1
                while lookahead < characters.count,
                      characters[lookahead].isWhitespace {
                    lookahead += 1
                }
                if lookahead < characters.count,
                   characters[lookahead] == "}" || characters[lookahead] == "]" {
                    index += 1
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output
    }
}
