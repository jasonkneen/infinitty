import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// On-device command completion via Apple's Foundation Models (macOS 26+,
/// Apple Intelligence). Private, no network, no API key. Each completion uses
/// a fresh session so suggestions stay independent; the underlying model is
/// kept warm.
@available(macOS 26.0, *)
final class FoundationModelHinter {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private let instructions = """
    You autocomplete partial macOS shell commands. Given the partial command the \
    user has typed, reply with ONLY the single full command line they most likely \
    intend — including the text they already typed as a prefix. No explanation, no \
    markdown, no backticks, no quotes around the whole thing, one line only.
    """

    init() {
        // Warm the model so the first real completion is fast.
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
    }

    func complete(_ input: String, cwd: String?) async -> String? {
        let session = LanguageModelSession(instructions: instructions)
        let prompt = cwd.map { "cwd: \($0)\npartial: \(input)" } ?? "partial: \(input)"
        let options = GenerationOptions(temperature: 0.15)
        guard let response = try? await session.respond(to: prompt, options: options) else {
            return nil
        }
        var text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Model sometimes wraps in backticks or adds a trailing newline/comment.
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        if let nl = text.firstIndex(of: "\n") { text = String(text[..<nl]) }
        return text.isEmpty ? nil : text
    }
}
#endif
