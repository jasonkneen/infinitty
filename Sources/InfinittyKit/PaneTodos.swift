import AppKit

/// One item of an agent-published plan/todo list attached to a pane.
struct PaneTodo: Equatable {
    let text: String
    let done: Bool
    let active: Bool
}

enum PaneTodoParser {
    /// Accepts a JSON array of strings or objects. Object keys follow either
    /// the generic {text, done} shape or Claude Code's TodoWrite shape
    /// {content, status: pending|in_progress|completed, activeForm}.
    static func parse(_ json: String) -> [PaneTodo]? {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        return array.compactMap { entry in
            if let text = entry as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : PaneTodo(text: trimmed, done: false, active: false)
            }
            guard let dict = entry as? [String: Any],
                  let text = (dict["text"] as? String) ?? (dict["content"] as? String),
                  !text.isEmpty else { return nil }
            let status = (dict["status"] as? String)?.lowercased()
            return PaneTodo(
                text: text,
                done: dict["done"] as? Bool ?? (status == "completed"),
                active: status == "in_progress")
        }
    }

    static func encode(_ todos: [PaneTodo]) -> String {
        let array = todos.map {
            ["text": $0.text, "done": $0.done, "active": $0.active] as [String: Any]
        }
        let data = (try? JSONSerialization.data(withJSONObject: array)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The checklist content of the pane-header todo popover.
final class PaneTodoListView: NSView {
    static let width: CGFloat = 300

    init(todos: [PaneTodo]) {
        super.init(frame: .zero)
        let rows = todos.map { Self.row(for: $0) }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func row(for todo: PaneTodo) -> NSView {
        let symbol = todo.done
            ? "checkmark.circle.fill"
            : todo.active ? "circle.inset.filled" : "circle"
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        icon.contentTintColor = todo.done
            ? NSColor.systemGreen.withAlphaComponent(0.85)
            : todo.active ? CodePalette.selectionAccent : NSColor.tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: todo.text)
        label.font = .systemFont(ofSize: 12, weight: todo.active ? .semibold : .regular)
        label.textColor = todo.done
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.7)
            : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 7
        icon.widthAnchor.constraint(equalToConstant: 15).isActive = true
        return row
    }

    var rowCountForTesting: Int {
        (subviews.first as? NSStackView)?.arrangedSubviews.count ?? 0
    }
}
