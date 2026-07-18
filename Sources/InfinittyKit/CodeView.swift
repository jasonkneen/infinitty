import AppKit

/// One file-system entry in the code-view tree. Children load lazily on
/// expand; sorting is directories-first, then case-insensitive name order.
final class CodeFileNode {
    let url: URL
    let isDirectory: Bool
    /// Display name override (search results show repo-relative paths).
    let nameOverride: String?
    private var loadedChildren: [CodeFileNode]?

    init(url: URL, isDirectory: Bool, nameOverride: String? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.nameOverride = nameOverride
    }

    var children: [CodeFileNode] {
        if let loadedChildren { return loadedChildren }
        guard isDirectory,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: url, includingPropertiesForKeys: [.isDirectoryKey],
                  options: [])
        else {
            loadedChildren = []
            return []
        }
        let nodes = urls.map { child in
            CodeFileNode(
                url: child,
                isDirectory: (try? child.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false)
        }
        loadedChildren = Self.sort(nodes)
        return loadedChildren!
    }

    /// Directories first, then files; alphabetical within each group. Pure so
    /// it can be unit-tested without touching the disk.
    static func sort(_ nodes: [CodeFileNode]) -> [CodeFileNode] {
        nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.url.lastPathComponent.localizedStandardCompare(
                b.url.lastPathComponent) == .orderedAscending
        }
    }
}

/// Regex-based highlighting for the preview: comments, strings, numbers and
/// keywords for a handful of common languages. Intentionally lightweight —
/// this is a file peeker, not an editor.
enum CodeHighlighter {

    private struct Language {
        let keywords: [String]
        let lineComment: String?
        let blockComment: (open: String, close: String)?
        let quoteChars: [Character]
    }

    private static let cLike = Language(
        keywords: [
            "int", "char", "float", "double", "void", "struct", "if", "else",
            "return", "for", "while", "switch", "case", "break", "continue",
            "sizeof", "static", "const", "unsigned", "signed", "long", "short",
            "typedef", "enum", "union", "extern", "do", "default", "goto",
        ],
        lineComment: "//", blockComment: ("/*", "*/"), quoteChars: ["\"", "'"])
    private static let swift = Language(
        keywords: [
            "func", "let", "var", "if", "else", "return", "struct", "class",
            "enum", "import", "guard", "switch", "case", "default", "for",
            "while", "in", "protocol", "extension", "init", "deinit", "self",
            "Self", "super", "true", "false", "nil", "typealias", "where",
            "public", "private", "internal", "fileprivate", "open", "static",
            "final", "override", "mutating", "lazy", "weak", "unowned", "some",
            "any", "async", "await", "throws", "throw", "try", "catch", "defer",
            "do", "inout", "is", "as", "break", "continue", "fallthrough",
        ],
        lineComment: "//", blockComment: ("/*", "*/"), quoteChars: ["\""])
    private static let jsLike = Language(
        keywords: [
            "const", "let", "var", "function", "return", "if", "else", "for",
            "while", "class", "import", "export", "from", "new", "typeof",
            "instanceof", "async", "await", "try", "catch", "finally", "throw",
            "switch", "case", "default", "break", "continue", "do", "this",
            "null", "undefined", "true", "false", "interface", "type", "enum",
            "implements", "extends", "of", "in", "yield", "static", "get",
            "set", "readonly", "public", "private", "protected", "void",
        ],
        lineComment: "//", blockComment: ("/*", "*/"), quoteChars: ["\"", "'", "`"])
    private static let python = Language(
        keywords: [
            "def", "class", "return", "if", "elif", "else", "for", "while",
            "import", "from", "as", "try", "except", "finally", "raise", "with",
            "lambda", "pass", "break", "continue", "global", "nonlocal", "True",
            "False", "None", "and", "or", "not", "is", "in", "yield", "async",
            "await", "del", "assert", "print",
        ],
        lineComment: "#", blockComment: nil, quoteChars: ["\"", "'"])
    private static let go = Language(
        keywords: [
            "func", "package", "import", "return", "if", "else", "for", "range",
            "switch", "case", "default", "break", "continue", "go", "defer",
            "chan", "select", "struct", "interface", "type", "map", "var",
            "const", "nil", "true", "false", "fallthrough", "goto",
        ],
        lineComment: "//", blockComment: ("/*", "*/"), quoteChars: ["\"", "'", "`"])
    private static let rust = Language(
        keywords: [
            "fn", "let", "mut", "if", "else", "match", "return", "struct",
            "enum", "impl", "trait", "use", "mod", "pub", "for", "while",
            "loop", "in", "break", "continue", "self", "Self", "super",
            "crate", "true", "false", "const", "static", "type", "where",
            "async", "await", "move", "ref", "dyn", "unsafe", "as",
        ],
        lineComment: "//", blockComment: ("/*", "*/"), quoteChars: ["\""])
    private static let shell = Language(
        keywords: [
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do",
            "done", "case", "esac", "function", "in", "echo", "export", "local",
            "return", "source", "alias", "set", "unset", "cd", "eval", "exec",
        ],
        lineComment: "#", blockComment: nil, quoteChars: ["\"", "'", "`"])
    private static let data = Language( // json/yaml/toml-ish
        keywords: ["true", "false", "null", "yes", "no", "on", "off"],
        lineComment: nil, blockComment: nil, quoteChars: ["\""])

    private static func language(forExtension ext: String) -> Language {
        switch ext {
        case "swift": return swift
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": return jsLike
        case "py", "rb", "pl": return python
        case "go": return go
        case "rs": return rust
        case "sh", "zsh", "bash": return shell
        case "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "cs": return cLike
        case "json": return Language(
            keywords: ["true", "false", "null"],
            lineComment: nil, blockComment: nil, quoteChars: ["\""])
        case "yaml", "yml", "toml": return Language(
            keywords: data.keywords, lineComment: "#", blockComment: nil,
            quoteChars: ["\"", "'"])
        default: return Language(
            keywords: [], lineComment: nil, blockComment: nil, quoteChars: ["\"", "'"])
        }
    }

    // One Dark hues, matching the terminal's default palette.
    private static let commentColor = NSColor(calibratedRed: 0x5C / 255, green: 0x63 / 255, blue: 0x70 / 255, alpha: 1)
    private static let stringColor = NSColor(calibratedRed: 0x98 / 255, green: 0xC3 / 255, blue: 0x79 / 255, alpha: 1)
    private static let numberColor = NSColor(calibratedRed: 0xD1 / 255, green: 0x9A / 255, blue: 0x66 / 255, alpha: 1)
    private static let keywordColor = NSColor(calibratedRed: 0xC6 / 255, green: 0x78 / 255, blue: 0xDD / 255, alpha: 1)

    /// Colors `text` in place. Pass the file extension (lowercased) to pick a
    /// language; unknown extensions get string-only highlighting.
    static func highlight(_ text: NSMutableAttributedString, ext: String) {
        let lang = language(forExtension: ext)
        let full = NSRange(location: 0, length: text.length)
        let plain = text.string as NSString

        var protected: [NSRange] = [] // comments + strings; keywords skip these

        func mark(_ range: NSRange, _ color: NSColor) {
            guard range.location != NSNotFound, range.length > 0,
                  NSMaxRange(range) <= text.length else { return }
            text.addAttribute(.foregroundColor, value: color, range: range)
        }

        if let block = lang.blockComment {
            let pattern = "\\Q\(block.open)\\E[\\s\\S]*?\\Q\(block.close)\\E"
            if let rx = try? NSRegularExpression(pattern: pattern) {
                for m in rx.matches(in: text.string, range: full) {
                    mark(m.range, commentColor)
                    protected.append(m.range)
                }
            }
        }
        if let line = lang.lineComment {
            let pattern = "\\Q\(line)\\E[^\\n]*"
            if let rx = try? NSRegularExpression(pattern: pattern) {
                for m in rx.matches(in: text.string, range: full)
                where !protected.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                    mark(m.range, commentColor)
                    protected.append(m.range)
                }
            }
        }
        for quote in lang.quoteChars {
            let q = NSRegularExpression.escapedPattern(for: String(quote))
            let pattern = "\(q)(?:\\\\.|[^\(q)\\\\\\n])*\(q)"
            if let rx = try? NSRegularExpression(pattern: pattern) {
                for m in rx.matches(in: text.string, range: full)
                where !protected.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                    mark(m.range, stringColor)
                    protected.append(m.range)
                }
            }
        }
        if let rx = try? NSRegularExpression(
            pattern: "\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b") {
            for m in rx.matches(in: text.string, range: full)
            where !protected.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                mark(m.range, numberColor)
            }
        }
        if !lang.keywords.isEmpty {
            let pattern = "\\b(?:" + lang.keywords.joined(separator: "|") + ")\\b"
            if let rx = try? NSRegularExpression(pattern: pattern) {
                for m in rx.matches(in: plain as String, range: full)
                where !protected.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                    mark(m.range, keywordColor)
                }
            }
        }
    }
}

/// File/change row cell: icon, name, and a right-aligned git status badge
/// (hidden for plain file rows).
final class CodeTableCellView: NSTableCellView {
    let badge = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        badge.alignment = .center
        badge.font = .systemFont(ofSize: 9, weight: .semibold)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Draws the selection as a rounded indigo pill instead of the system gray.
/// Draws a compact neutral selection without using the system accent color.
final class CodeRowView: NSTableRowView {
    static let emphasizedSelectionColor = CodePalette.selectionFill

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let color = isEmphasized
            ? Self.emphasizedSelectionColor
            : NSColor(calibratedWhite: 0.18, alpha: 1)
        color.setFill()
        path.fill()
    }
}

/// Diff table cell with a settable background tint (add/del/hunk rows).
final class DiffCellView: NSTableCellView {
    var tint: NSColor? {
        didSet {
            wantsLayer = true
            layer?.backgroundColor = tint?.cgColor
        }
    }
}

/// The code-view sidebar. Top to bottom: Files|Changes segmented control,
/// rg-backed search field (or per-status change counts and a commit box on
/// the Changes page), current-folder header, then a file tree (or flat
/// search / git-status results) above a read-only preview, with a branch
/// footer at the bottom. Markdown renders by default with a Raw toggle; git
/// changes preview as diffs and can be staged, committed and switched
/// between branches in place. Follows the tracked session's live cwd
/// (2s tracker poll, debounced).
final class CodeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private enum Page: Int { case files = 0, changes = 1, chat = 2 }
    private enum DiffMode { case combined, split }

    private let config: AppConfig
    private weak var session: TerminalSession?
    private var cwdObserver: NSObjectProtocol?

    // UI
    private let pageControl = CodeSegmentedBar(
        labels: ["FILES", "CHANGES", "CHAT"],
        fontSize: 12, fontWeight: .medium, squared: true)
    private let searchField = NSSearchField()
    private let statsRow = NSView()
    private var statCountFields: [NSTextField] = []
    private let commitRow = NSView()
    private let commitField = NSTextField()
    private let commitButton = NSButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let stageAllButton = NSButton()
    private let outlineView = NSOutlineView()
    private let textView = NSTextView()
    private let previewScroll = NSScrollView()
    private let previewTitle = NSTextField(labelWithString: "")
    private let markdownToggle = CodeSegmentedBar(labels: ["Rendered", "Raw"], fontSize: 10)
    private let stageButton = NSButton()
    private let branchFooter = NSView()
    private let branchButton = NSButton()
    private let header = NSView()
    private let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
    private let chatHost = NSView()
    private weak var assistant: PetAssistant?
    private var selectedChange: CodeChange?
    private var headerTopToSearch: NSLayoutConstraint?
    private var headerTopToCommit: NSLayoutConstraint?
    private var splitBottomToFooter: NSLayoutConstraint?
    private var splitBottomToContainer: NSLayoutConstraint?

    // Diff viewer UI (changes preview)
    private let diffToolbar = NSView()
    private let unifiedButton = NSButton()
    private let splitDiffButton = NSButton()
    private let fontDownButton = NSButton()
    private let fontUpButton = NSButton()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let diffScroll = NSScrollView()
    private let diffTable = NSTableView()

    // Files state
    private var page: Page = .files
    private var root: CodeFileNode?
    private var rootPath: String?
    private var pendingReRoot: DispatchWorkItem?
    private var searchResults: [CodeFileNode]?
    private var fileListCache: [String]?
    private var pendingSearch: DispatchWorkItem?

    // Changes state
    private var changes: [CodeChange] = []
    private var changesRepo: String?
    private var changesBranch: String?
    private var notARepo = false
    private var statusError: String?

    // Preview state
    private var previewedURL: URL?
    private var previewRaw: String?
    private var markdownRendered = true
    private var previewGeneration = 0 // guards stale async diff callbacks

    // Diff viewer state
    private var parsedDiff: [DiffLine] = []
    private var splitDiff: [SplitDiffRow] = []
    private var showingDiff = false
    private var diffMode: DiffMode = .combined
    private var diffFontSize: CGFloat

    init(config: AppConfig) {
        let saved = UserDefaults.standard.double(forKey: "codeDiffFontSize")
        // Diffs default to half the terminal font size — dense overview,
        // adjustable with the A−/A+ buttons (persisted).
        self.diffFontSize = saved > 0 ? CGFloat(saved) : config.fontSize * 0.5
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let cwdObserver { NotificationCenter.default.removeObserver(cwdObserver) }
        pendingReRoot?.cancel()
        pendingSearch?.cancel()
    }

    // MARK: - layout

    override func loadView() {
        let container = NSView()

        pageControl.onChange = { [weak self] index in
            self?.setPage(Page(rawValue: index) ?? .files)
        }

        searchField.placeholderString = "Search files"
        searchField.font = .systemFont(ofSize: NSFont.systemFontSize)
        searchField.controlSize = .regular
        searchField.isBezeled = false
        searchField.drawsBackground = true
        searchField.backgroundColor = NSColor(white: 1, alpha: 0.07)
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = 6
        searchField.layer?.borderWidth = 1
        searchField.layer?.borderColor = CodePalette.hairline.cgColor
        searchField.layer?.masksToBounds = true
        searchField.delegate = self
        // Changes-page stats: one compact centered line of badge + count chips.
        let statsStack = NSStackView()
        statsStack.orientation = .horizontal
        statsStack.spacing = 12
        statsStack.alignment = .centerY
        for (name, color) in Self.statCategories {
            let chip = Self.statChip(name: name, color: color)
            statCountFields.append(chip.count)
            statsStack.addArrangedSubview(chip.view)
        }
        statsRow.addSubview(statsStack)
        statsStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statsStack.centerXAnchor.constraint(equalTo: statsRow.centerXAnchor),
            statsStack.centerYAnchor.constraint(equalTo: statsRow.centerYAnchor),
        ])
        statsRow.isHidden = true

        // Commit row: message field + button (Changes page only). Enabled
        // when there's a message and at least one staged change.
        commitField.placeholderString = "Commit message"
        commitField.controlSize = .small
        commitField.bezelStyle = .roundedBezel
        commitField.delegate = self
        commitField.target = self
        commitField.action = #selector(commitTapped(_:))
        commitButton.title = "Commit"
        commitButton.bezelStyle = .rounded
        commitButton.controlSize = .small
        commitButton.target = self
        commitButton.action = #selector(commitTapped(_:))
        commitButton.isEnabled = false
        commitRow.addSubview(commitField)
        commitRow.addSubview(commitButton)
        commitRow.isHidden = true

        // Header: current folder (files) or repo • branch (changes) + refresh.
        pathLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        let refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise",
                           accessibilityDescription: "Refresh") ?? NSImage(),
            target: self, action: #selector(refreshTapped(_:)))
        refreshButton.bezelStyle = .inline
        refreshButton.isBordered = false
        stageAllButton.title = "Stage All"
        stageAllButton.bezelStyle = .rounded
        stageAllButton.controlSize = .small
        stageAllButton.target = self
        stageAllButton.action = #selector(stageAllTapped(_:))
        stageAllButton.isHidden = true
        let headerHairline = Self.hairline()
        header.addSubview(pathLabel)
        header.addSubview(stageAllButton)
        header.addSubview(refreshButton)
        header.addSubview(headerHairline)

        // File tree / results list.
        let treeScroll = NSScrollView()
        treeScroll.hasVerticalScroller = true
        treeScroll.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .medium
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.indentationPerLevel = 13
        outlineView.dataSource = self
        outlineView.delegate = self
        treeScroll.documentView = outlineView

        // Preview header: file name + markdown Rendered/Raw toggle.
        let previewHeader = NSView()
        previewTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        previewTitle.textColor = .secondaryLabelColor
        previewTitle.lineBreakMode = .byTruncatingMiddle
        markdownToggle.onChange = { [weak self] index in
            self?.markdownRendered = index == 0
            self?.renderPreview()
        }
        markdownToggle.isHidden = true
        stageButton.bezelStyle = .rounded
        stageButton.controlSize = .small
        stageButton.target = self
        stageButton.action = #selector(stageTapped(_:))
        stageButton.isHidden = true
        let previewHairline = Self.hairline()
        previewHeader.addSubview(previewTitle)
        previewHeader.addSubview(markdownToggle)
        previewHeader.addSubview(stageButton)
        previewHeader.addSubview(previewHairline)

        // Preview.
        previewScroll.hasVerticalScroller = true
        previewScroll.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = previewFont()
        textView.textColor = .textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        previewScroll.documentView = textView

        // Diff viewer: mode icons + font size on the right of a toolbar over
        // the diff table. Hidden until a diff is selected.
        unifiedButton.image = NSImage(
            systemSymbolName: "list.bullet",
            accessibilityDescription: "Combined diff")
        splitDiffButton.image = NSImage(
            systemSymbolName: "rectangle.split.2x1",
            accessibilityDescription: "Side-by-side diff")
        for button in [unifiedButton, splitDiffButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.target = self
        }
        unifiedButton.action = #selector(unifiedTapped(_:))
        splitDiffButton.action = #selector(splitTapped(_:))
        updateDiffModeIcons()
        fontDownButton.title = "A−"
        fontUpButton.title = "A+"
        for button in [fontDownButton, fontUpButton] {
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.bezelStyle = .inline
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.target = self
        }
        fontDownButton.action = #selector(fontDownTapped(_:))
        fontUpButton.action = #selector(fontUpTapped(_:))
        fontSizeLabel.font = .systemFont(ofSize: 9, weight: .medium)
        fontSizeLabel.textColor = .secondaryLabelColor
        fontSizeLabel.alignment = .center
        fontSizeLabel.stringValue = "\(Int(diffFontSize))"
        let diffToolbarHairline = Self.hairline()
        diffToolbar.addSubview(unifiedButton)
        diffToolbar.addSubview(splitDiffButton)
        diffToolbar.addSubview(fontDownButton)
        diffToolbar.addSubview(fontSizeLabel)
        diffToolbar.addSubview(fontUpButton)
        diffToolbar.addSubview(diffToolbarHairline)
        diffToolbar.isHidden = true

        diffScroll.hasVerticalScroller = true
        diffScroll.hasHorizontalScroller = true
        diffScroll.drawsBackground = false
        diffTable.headerView = nil
        diffTable.rowSizeStyle = .custom
        diffTable.selectionHighlightStyle = .none
        diffTable.columnAutoresizingStyle = .noColumnAutoresizing
        diffTable.intercellSpacing = NSSize(width: 0, height: 0)
        diffTable.backgroundColor = .clear
        diffTable.dataSource = self
        diffTable.delegate = self
        diffScroll.documentView = diffTable
        diffScroll.isHidden = true

        let previewContainer = NSView()
        previewContainer.addSubview(previewHeader)
        previewContainer.addSubview(previewScroll)
        previewContainer.addSubview(diffToolbar)
        previewContainer.addSubview(diffScroll)
        previewHeader.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        diffToolbar.translatesAutoresizingMaskIntoConstraints = false
        diffScroll.translatesAutoresizingMaskIntoConstraints = false
        unifiedButton.translatesAutoresizingMaskIntoConstraints = false
        splitDiffButton.translatesAutoresizingMaskIntoConstraints = false
        fontDownButton.translatesAutoresizingMaskIntoConstraints = false
        fontUpButton.translatesAutoresizingMaskIntoConstraints = false
        fontSizeLabel.translatesAutoresizingMaskIntoConstraints = false
        diffToolbarHairline.translatesAutoresizingMaskIntoConstraints = false
        previewTitle.translatesAutoresizingMaskIntoConstraints = false
        markdownToggle.translatesAutoresizingMaskIntoConstraints = false
        previewHairline.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewHeader.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewHeader.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewHeader.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewHeader.heightAnchor.constraint(equalToConstant: 26),

            previewTitle.leadingAnchor.constraint(equalTo: previewHeader.leadingAnchor, constant: 8),
            previewTitle.centerYAnchor.constraint(equalTo: previewHeader.centerYAnchor),
            previewTitle.trailingAnchor.constraint(lessThanOrEqualTo: markdownToggle.leadingAnchor, constant: -4),

            markdownToggle.trailingAnchor.constraint(equalTo: previewHeader.trailingAnchor, constant: -6),
            markdownToggle.centerYAnchor.constraint(equalTo: previewHeader.centerYAnchor),
            markdownToggle.heightAnchor.constraint(equalToConstant: 20),

            stageButton.trailingAnchor.constraint(equalTo: previewHeader.trailingAnchor, constant: -6),
            stageButton.centerYAnchor.constraint(equalTo: previewHeader.centerYAnchor),

            previewHairline.leadingAnchor.constraint(equalTo: previewHeader.leadingAnchor),
            previewHairline.trailingAnchor.constraint(equalTo: previewHeader.trailingAnchor),
            previewHairline.bottomAnchor.constraint(equalTo: previewHeader.bottomAnchor),
            previewHairline.heightAnchor.constraint(equalToConstant: 1),

            previewScroll.topAnchor.constraint(equalTo: previewHeader.bottomAnchor),
            previewScroll.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),

            diffToolbar.topAnchor.constraint(equalTo: previewHeader.bottomAnchor),
            diffToolbar.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            diffToolbar.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            diffToolbar.heightAnchor.constraint(equalToConstant: 24),

            splitDiffButton.trailingAnchor.constraint(equalTo: diffToolbar.trailingAnchor, constant: -8),
            splitDiffButton.centerYAnchor.constraint(equalTo: diffToolbar.centerYAnchor),
            unifiedButton.trailingAnchor.constraint(equalTo: splitDiffButton.leadingAnchor, constant: -4),
            unifiedButton.centerYAnchor.constraint(equalTo: diffToolbar.centerYAnchor),

            fontUpButton.trailingAnchor.constraint(equalTo: unifiedButton.leadingAnchor, constant: -10),
            fontUpButton.centerYAnchor.constraint(equalTo: diffToolbar.centerYAnchor),
            fontSizeLabel.trailingAnchor.constraint(equalTo: fontUpButton.leadingAnchor, constant: -2),
            fontSizeLabel.centerYAnchor.constraint(equalTo: diffToolbar.centerYAnchor),
            fontSizeLabel.widthAnchor.constraint(equalToConstant: 18),
            fontDownButton.trailingAnchor.constraint(equalTo: fontSizeLabel.leadingAnchor, constant: -2),
            fontDownButton.centerYAnchor.constraint(equalTo: diffToolbar.centerYAnchor),

            diffToolbarHairline.leadingAnchor.constraint(equalTo: diffToolbar.leadingAnchor),
            diffToolbarHairline.trailingAnchor.constraint(equalTo: diffToolbar.trailingAnchor),
            diffToolbarHairline.bottomAnchor.constraint(equalTo: diffToolbar.bottomAnchor),
            diffToolbarHairline.heightAnchor.constraint(equalToConstant: 1),

            diffScroll.topAnchor.constraint(equalTo: diffToolbar.bottomAnchor),
            diffScroll.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            diffScroll.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            diffScroll.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
        ])

        // Deterministic initial layout: the tree gets a real share from the
        // start, and the preview (lower holding priority) absorbs every later
        // resize. Seeding the divider in viewDidLayout is NOT safe — the live
        // window can lay the sidebar out at a stub height first, which leaves
        // the tree squashed at 0pt when it grows.
        split.isVertical = false
        split.dividerStyle = .thin
        treeScroll.frame = NSRect(x: 0, y: 275, width: 280, height: 225)
        previewContainer.frame = NSRect(x: 0, y: 0, width: 280, height: 275)
        split.addArrangedSubview(treeScroll)
        split.addArrangedSubview(previewContainer)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        // Solid backdrop matching the terminal theme — the window itself can
        // be translucent, so without this the terminal behind bleeds through.
        let themeBG = Theme.dark.applying(config).background
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor(
            red: CGFloat(themeBG.x), green: CGFloat(themeBG.y),
            blue: CGFloat(themeBG.z), alpha: 1)

        // Branch footer: current branch, click to switch. Hidden outside repos.
        let footerHairline = Self.hairline()
        branchButton.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "Branch")
        branchButton.imagePosition = .imageLeading
        branchButton.bezelStyle = .inline
        branchButton.isBordered = false
        branchButton.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        branchButton.contentTintColor = .secondaryLabelColor
        branchButton.target = self
        branchButton.action = #selector(showBranchMenu(_:))
        branchFooter.addSubview(branchButton)
        branchFooter.addSubview(footerHairline)
        branchFooter.isHidden = true

        container.addSubview(pageControl)
        container.addSubview(searchField)
        container.addSubview(statsRow)
        container.addSubview(commitRow)
        container.addSubview(header)
        container.addSubview(split)
        container.addSubview(branchFooter)
        container.addSubview(chatHost)
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        statsRow.translatesAutoresizingMaskIntoConstraints = false
        commitRow.translatesAutoresizingMaskIntoConstraints = false
        commitField.translatesAutoresizingMaskIntoConstraints = false
        commitButton.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        split.translatesAutoresizingMaskIntoConstraints = false
        branchFooter.translatesAutoresizingMaskIntoConstraints = false
        chatHost.translatesAutoresizingMaskIntoConstraints = false
        branchButton.translatesAutoresizingMaskIntoConstraints = false
        footerHairline.translatesAutoresizingMaskIntoConstraints = false
        stageAllButton.translatesAutoresizingMaskIntoConstraints = false
        stageButton.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        headerHairline.translatesAutoresizingMaskIntoConstraints = false
        headerTopToSearch = header.topAnchor.constraint(
            equalTo: searchField.bottomAnchor, constant: 4)
        headerTopToCommit = header.topAnchor.constraint(
            equalTo: commitRow.bottomAnchor, constant: 6)
        headerTopToCommit?.isActive = false
        splitBottomToFooter = split.bottomAnchor.constraint(equalTo: branchFooter.topAnchor)
        splitBottomToContainer = split.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        splitBottomToFooter?.isActive = false
        NSLayoutConstraint.activate([
            pageControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            // Natural width, centered — a compact tabbed bar, not a banner.
            pageControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            // Explicit height: relying on intrinsicContentSize proved fragile
            // in the live window's split-view layout (the bar ballooned).
            pageControl.heightAnchor.constraint(equalToConstant: 26),

            searchField.topAnchor.constraint(equalTo: pageControl.bottomAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            statsRow.topAnchor.constraint(equalTo: pageControl.bottomAnchor, constant: 6),
            statsRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statsRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            statsRow.heightAnchor.constraint(equalToConstant: 20),

            commitRow.topAnchor.constraint(equalTo: statsRow.bottomAnchor, constant: 4),
            commitRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            commitRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            commitRow.heightAnchor.constraint(equalToConstant: 26),

            commitField.leadingAnchor.constraint(equalTo: commitRow.leadingAnchor),
            commitField.centerYAnchor.constraint(equalTo: commitRow.centerYAnchor),
            commitField.trailingAnchor.constraint(equalTo: commitButton.leadingAnchor, constant: -6),

            commitButton.trailingAnchor.constraint(equalTo: commitRow.trailingAnchor),
            commitButton.centerYAnchor.constraint(equalTo: commitRow.centerYAnchor),

            headerTopToSearch!,

            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),

            pathLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            pathLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: stageAllButton.leadingAnchor, constant: -4),

            stageAllButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            stageAllButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            refreshButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            headerHairline.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerHairline.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerHairline.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerHairline.heightAnchor.constraint(equalToConstant: 1),

            split.topAnchor.constraint(equalTo: header.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitBottomToContainer!,

            chatHost.topAnchor.constraint(equalTo: pageControl.bottomAnchor, constant: 6),
            chatHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chatHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chatHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            branchFooter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            branchFooter.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            branchFooter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            branchFooter.heightAnchor.constraint(equalToConstant: 26),

            branchButton.leadingAnchor.constraint(equalTo: branchFooter.leadingAnchor, constant: 8),
            branchButton.centerYAnchor.constraint(equalTo: branchFooter.centerYAnchor),

            footerHairline.leadingAnchor.constraint(equalTo: branchFooter.leadingAnchor),
            footerHairline.trailingAnchor.constraint(equalTo: branchFooter.trailingAnchor),
            footerHairline.topAnchor.constraint(equalTo: branchFooter.topAnchor),
            footerHairline.heightAnchor.constraint(equalToConstant: 1),
        ])
        chatHost.isHidden = true
        view = container
    }

    private static func hairline() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = CodePalette.hairline.cgColor
        return view
    }

    private static let statCategories: [(name: String, color: NSColor)] = [
        ("M", NSColor(calibratedRed: 0xE5 / 255, green: 0xC0 / 255, blue: 0x7B / 255, alpha: 1)),
        ("??", diffAddColor),
        ("A", diffAddColor),
        ("D", diffDelColor),
    ]

    private static func statChip(name: String, color: NSColor) -> (view: NSView, count: NSTextField) {
        let chip = NSView()
        let badge = NSTextField(labelWithString: name)
        badge.alignment = .center
        badge.font = .systemFont(ofSize: 9, weight: .semibold)
        badge.textColor = color
        badge.wantsLayer = true
        badge.layer?.backgroundColor = color.withAlphaComponent(0.22).cgColor
        badge.layer?.cornerRadius = 4
        let count = NSTextField(labelWithString: "0")
        count.font = .systemFont(ofSize: 11, weight: .semibold)
        count.textColor = .labelColor
        chip.addSubview(badge)
        chip.addSubview(count)
        badge.translatesAutoresizingMaskIntoConstraints = false
        count.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
            badge.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 14),
            count.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 4),
            count.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            count.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
        ])
        return (chip, count)
    }

    private func updateChangeStats() {
        var counts = [0, 0, 0, 0] // modified, untracked, added, deleted
        for change in changes {
            switch change.label {
            case "??": counts[1] += 1
            case "A": counts[2] += 1
            case "D": counts[3] += 1
            default: counts[0] += 1
            }
        }
        for (i, field) in statCountFields.enumerated() {
            field.stringValue = "\(counts[i])"
        }
    }

    // MARK: - staging + branch switching

    private func updateStageButton() {
        stageButton.isHidden = selectedChange == nil
        stageButton.title = selectedChange?.isStaged == true ? "Unstage" : "Stage"
    }

    private func updateStageAllButton() {
        stageAllButton.isHidden = page != .changes || changes.isEmpty
    }

    private func updateBranchFooter() {
        let inRepo = changesRepo != nil && page != .chat
        branchFooter.isHidden = !inRepo
        branchButton.title = changesBranch ?? "detached HEAD"
        splitBottomToFooter?.isActive = inRepo
        splitBottomToContainer?.isActive = !inRepo
    }

    /// Run a git mutation off-thread: refresh on success; on failure show
    /// git's error, with a one-click lock removal + retry when the cause is
    /// a stale .git/index.lock. Failures here used to be swallowed, which
    /// read as "the button does nothing".
    private func runGitMutation(
        _ message: String, _ operation: @escaping () -> String?,
        onSuccess: (() -> Void)? = nil
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = operation()
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.showGitError(error, message: message) {
                        self.runGitMutation(message, operation, onSuccess: onSuccess)
                    }
                } else {
                    onSuccess?()
                    self.refreshChanges()
                }
            }
        }
    }

    @objc private func commitTapped(_ sender: Any?) {
        let message = commitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let repo = changesRepo else { return }
        runGitMutation("Could not commit", { CodeGit.commit(in: repo, message: message) }) { [weak self] in
            self?.commitField.stringValue = ""
        }
    }

    private func updateCommitControls() {
        let hasStaged = changes.contains { $0.isStaged }
        let hasMessage = !commitField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        commitButton.isEnabled = hasStaged && hasMessage
    }

    @objc private func stageTapped(_ sender: Any?) {
        guard let change = selectedChange, let repo = changesRepo else { return }
        let stage = !change.isStaged
        runGitMutation("Could not \(stage ? "stage" : "unstage") \(change.path)") {
            stage
                ? CodeGit.stage(in: repo, path: change.path)
                : CodeGit.unstage(in: repo, path: change.path)
        }
    }

    @objc private func stageAllTapped(_ sender: Any?) {
        guard let repo = changesRepo else { return }
        runGitMutation("Could not stage all changes") { CodeGit.stageAll(in: repo) }
    }

    /// True when a git error is the stale-index-lock failure.
    static func isLockError(_ error: String) -> Bool {
        error.contains("index.lock")
    }

    /// Delete `repo`'s .git/index.lock. Only ever called on explicit user
    /// confirmation from the error alert.
    @discardableResult
    static func removeIndexLock(in repo: String) -> Bool {
        (try? FileManager.default.removeItem(
            atPath: repo + "/.git/index.lock")) != nil
    }

    private func showGitError(_ error: String, message: String, retry: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if Self.isLockError(error), let repo = changesRepo {
            alert.messageText = "Git index is locked"
            alert.informativeText = error
                + "\n\nNo other git process should be using this repository — "
                + "a stale .git/index.lock is safe to remove."
            alert.addButton(withTitle: "Remove Lock and Retry")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Self.removeIndexLock(in: repo)
                retry()
            }
            return
        }
        alert.messageText = message
        alert.informativeText = error
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showBranchMenu(_ sender: Any?) {
        guard let repo = changesRepo else { return }
        let branches = CodeGit.branches(in: repo)
        guard !branches.isEmpty else { return }
        let menu = NSMenu()
        for branch in branches {
            let item = NSMenuItem(
                title: branch, action: #selector(branchPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = branch
            item.state = branch == changesBranch ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: branchButton.bounds.height + 4),
            in: branchButton)
    }

    @objc private func branchPicked(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String,
              branch != changesBranch, let repo = changesRepo else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = CodeGit.checkout(in: repo, branch: branch)
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "Could not switch to \(branch)"
                    alert.informativeText = error
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
                // The working tree changed out from under the file list.
                let path = self.rootPath
                self.rootPath = nil
                self.reRoot(path)
            }
        }
    }

    // MARK: - session tracking

    /// Point the sidebar at `session`'s live folder and start following its
    /// cwd changes.
    func track(session: TerminalSession) {
        guard session !== self.session else { return }
        if let cwdObserver { NotificationCenter.default.removeObserver(cwdObserver) }
        self.session = session
        if let tracker = session.processTracker {
            cwdObserver = NotificationCenter.default.addObserver(
                forName: ForegroundProcessTracker.cwdDidChangeNotification,
                object: tracker, queue: .main
            ) { [weak self] note in
                guard let self,
                      let path = note.userInfo?[ForegroundProcessTracker.cwdKey] as? String
                else { return }
                self.reRootDebounced(path)
            }
        }
        reRoot(session.currentDirectory())
    }

    func attachAssistant(_ assistant: PetAssistant) {
        if self.assistant === assistant, !chatHost.subviews.isEmpty { return }
        self.assistant = assistant
        chatHost.subviews.forEach { $0.removeFromSuperview() }
        let panel = assistant.makeSidebarPanelView()
        panel.removeFromSuperview()
        chatHost.addSubview(panel)
        panel.onClose = { [weak self] in self?.setPage(.files) }
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: chatHost.topAnchor),
            panel.leadingAnchor.constraint(equalTo: chatHost.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: chatHost.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: chatHost.bottomAnchor),
        ])
    }

    private func reRootDebounced(_ path: String) {
        pendingReRoot?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reRoot(path) }
        pendingReRoot = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reRoot(_ path: String?) {
        let resolved = (path?.isEmpty == false ? path : nil) ?? NSHomeDirectory()
        guard resolved != rootPath else { return }
        rootPath = resolved
        root = CodeFileNode(url: URL(fileURLWithPath: resolved), isDirectory: true)
        fileListCache = nil
        searchResults = nil
        searchField.stringValue = ""
        changes = []
        changesRepo = nil
        changesBranch = nil
        notARepo = false
        statusError = nil
        selectedChange = nil
        updateChangeStats()
        updateStageButton()
        updateBranchFooter()
        updateHeader()
        // Probe git on both pages: the branch footer needs it on Files too.
        refreshChanges()
        outlineView.reloadData()
        clearPreview()
    }

    // MARK: - pages

    private func setPage(_ newPage: Page) {
        page = newPage
        pageControl.setSelectedIndex(newPage.rawValue)
        searchField.isHidden = newPage != .files
        statsRow.isHidden = newPage != .changes
        commitRow.isHidden = newPage != .changes
        let showingChat = newPage == .chat
        chatHost.isHidden = !showingChat
        header.isHidden = showingChat
        split.isHidden = showingChat
        selectedChange = nil
        updateStageButton()
        updateStageAllButton()
        headerTopToSearch?.isActive = newPage != .changes
        headerTopToCommit?.isActive = newPage == .changes
        updateBranchFooter()
        updateHeader()
        if newPage == .changes { refreshChanges() }
        outlineView.reloadData()
    }

    /// Pet-assistant hand-off: show these root-relative paths as the current
    /// search results on the Files page.
    func showSearchResults(_ paths: [String], query: String?) {
        setPage(.files)
        if let query { searchField.stringValue = query }
        searchResults = searchNodes(from: paths)
        outlineView.reloadData()
    }

    private func updateHeader() {
        switch page {
        case .files:
            pathLabel.stringValue = rootPath
                .map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
        case .changes:
            if notARepo || changesRepo == nil {
                pathLabel.stringValue = "Not a git repository"
            } else if let statusError {
                pathLabel.stringValue = "Git error: \(Self.firstLine(statusError))"
            } else {
                let repo = (changesRepo! as NSString).lastPathComponent
                pathLabel.stringValue = changesBranch.map { "\(repo) • \($0)" } ?? repo
            }
        case .chat:
            pathLabel.stringValue = ""
        }
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
    }

    // MARK: - search (rg --files, filtered in memory)

    func controlTextDidChange(_ note: Notification) {
        if (note.object as? NSTextField) === commitField {
            updateCommitControls()
            return
        }
        guard note.object as? NSSearchField === searchField else { return }
        pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applySearch() }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func applySearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = nil
            outlineView.reloadData()
            return
        }
        if let cache = fileListCache {
            searchResults = searchNodes(from: CodeSearch.filter(cache, query: query))
            outlineView.reloadData()
            return
        }
        guard let rootPath else { return }
        let expected = rootPath
        CodeSearch.listFiles(root: expected) { [weak self] files in
            guard let self, self.rootPath == expected else { return }
            self.fileListCache = files
            // Re-read the field: the user may have typed more while rg ran.
            let q = self.searchField.stringValue.trimmingCharacters(in: .whitespaces)
            self.searchResults = q.isEmpty
                ? nil
                : self.searchNodes(from: CodeSearch.filter(files, query: q))
            self.outlineView.reloadData()
        }
    }

    private func searchNodes(from paths: [String]) -> [CodeFileNode] {
        guard let rootPath else { return [] }
        let base = URL(fileURLWithPath: rootPath)
        return paths.map {
            CodeFileNode(
                url: base.appendingPathComponent($0),
                isDirectory: false, nameOverride: $0)
        }
    }

    // MARK: - changes (git)

    private func refreshChanges() {
        guard let rootPath else { return }
        let expected = rootPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let repo = CodeGit.repoRoot(of: expected) else {
                DispatchQueue.main.async {
                    self?.applyChanges(nil, repo: nil, root: expected)
                }
                return
            }
            let status = CodeGit.status(in: repo)
            DispatchQueue.main.async {
                self?.applyChanges(status, repo: repo, root: expected)
            }
        }
    }

    private func applyChanges(
        _ status: CodeGit.RepoStatus?,
        repo: String?, root: String
    ) {
        guard root == rootPath else { return } // user cd'd while git ran
        // Keep the selected row across the reload so staging feedback is
        // visible: the badge goes solid and the button flips to Unstage.
        let previousPath = selectedChange?.path
        changesRepo = repo
        changes = status?.changes ?? []
        changesBranch = status?.branch ?? nil
        notARepo = repo == nil
        statusError = status?.error
        selectedChange = nil
        updateChangeStats()
        updateStageButton()
        updateStageAllButton()
        updateCommitControls()
        updateBranchFooter()
        updateHeader()
        if page == .changes {
            outlineView.reloadData()
            if let previousPath,
               let row = changes.firstIndex(where: { $0.path == previousPath }) {
                outlineView.selectRowIndexes(
                    IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }

    private func previewChange(_ change: CodeChange) {
        guard let repo = changesRepo else { return }
        previewGeneration += 1
        let generation = previewGeneration
        if change.isUntracked {
            loadPreview(for: URL(fileURLWithPath: repo)
                .appendingPathComponent(change.path))
            previewTitle.stringValue = change.path + " (new file)"
            return
        }
        previewTitle.stringValue = change.path
        previewedURL = nil
        previewRaw = nil
        updateMarkdownToggle()
        showPlaceholder("Loading diff…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = CodeGit.diff(in: repo, for: change)
            DispatchQueue.main.async {
                guard let self, self.previewGeneration == generation else { return }
                if let text = result.text, !text.isEmpty {
                    self.showDiff(text)
                } else if let error = result.error {
                    self.showPlaceholder("git diff failed: \(Self.firstLine(error))")
                } else {
                    self.showPlaceholder("No diff to show")
                }
            }
        }
    }

    private static let diffAddColor = NSColor(calibratedRed: 0x98 / 255, green: 0xC3 / 255, blue: 0x79 / 255, alpha: 1)
    private static let diffDelColor = NSColor(calibratedRed: 0xE0 / 255, green: 0x6C / 255, blue: 0x75 / 255, alpha: 1)
    private static let diffHunkColor = NSColor(calibratedRed: 0xC6 / 255, green: 0x78 / 255, blue: 0xDD / 255, alpha: 1)

    private func showDiff(_ diff: String) {
        parsedDiff = CodeDiff.parse(diff)
        splitDiff = CodeDiff.splitRows(from: parsedDiff)
        showingDiff = !parsedDiff.isEmpty
        guard showingDiff else {
            showPlaceholder("No diff to show")
            return
        }
        textView.string = "" // the table, not the text view, presents diffs
        updateDiffChrome()
        renderDiffTable()
    }

    // MARK: - diff viewer

    private func updateDiffChrome() {
        diffToolbar.isHidden = !showingDiff
        diffScroll.isHidden = !showingDiff
        previewScroll.isHidden = showingDiff
        fontSizeLabel.stringValue = "\(Int(diffFontSize))"
    }

    private func diffMonoFont() -> NSFont {
        if let name = config.fontName, let f = NSFont(name: name, size: diffFontSize) {
            return f
        }
        return .monospacedSystemFont(ofSize: diffFontSize, weight: .regular)
    }

    @objc private func fontDownTapped(_ sender: Any?) { adjustDiffFont(-1) }
    @objc private func fontUpTapped(_ sender: Any?) { adjustDiffFont(1) }
    @objc private func unifiedTapped(_ sender: Any?) { setDiffMode(.combined) }
    @objc private func splitTapped(_ sender: Any?) { setDiffMode(.split) }

    private func setDiffMode(_ mode: DiffMode) {
        diffMode = mode
        updateDiffModeIcons()
        renderDiffTable()
    }

    private func updateDiffModeIcons() {
        unifiedButton.contentTintColor = diffMode == .combined
            ? .labelColor : .secondaryLabelColor
        splitDiffButton.contentTintColor = diffMode == .split
            ? .labelColor : .secondaryLabelColor
    }

    private func adjustDiffFont(_ delta: CGFloat) {
        diffFontSize = min(max(diffFontSize + delta, 5), 24)
        UserDefaults.standard.set(Double(diffFontSize), forKey: "codeDiffFontSize")
        fontSizeLabel.stringValue = "\(Int(diffFontSize))"
        renderDiffTable()
    }

    private static let combinedColumnIDs = ["oldNo", "newNo", "mark", "text"]
    private static let splitColumnIDs = ["oldNo", "oldText", "newNo", "newText"]

    private func renderDiffTable() {
        guard showingDiff else { return }
        let font = diffMonoFont()
        diffTable.rowHeight = ceil(font.ascender - font.descender + 4)
        while let column = diffTable.tableColumns.first {
            diffTable.removeTableColumn(column)
        }
        // Drop stale row views before the new mode's columns arrive: AppKit
        // re-queries viewFor during addTableColumn, and the two modes have
        // different row counts.
        diffTable.reloadData()
        for id in diffMode == .combined ? Self.combinedColumnIDs : Self.splitColumnIDs {
            diffTable.addTableColumn(
                NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)))
        }
        diffTable.reloadData()
        applyDiffColumnWidths()
        diffTable.scrollToBeginningOfDocument(nil)
    }

    /// Columns fit their content, expanding to fill the sidebar when narrow;
    /// wider content scrolls horizontally.
    private func applyDiffColumnWidths() {
        let font = diffMonoFont()
        func textWidth(_ s: String) -> CGFloat {
            ceil((s as NSString).size(withAttributes: [.font: font]).width)
        }
        func setWidth(_ id: String, _ w: CGFloat) {
            diffTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id))?
                .width = w
        }
        let maxLine = max(
            parsedDiff.compactMap(\.oldLine).max() ?? 0,
            parsedDiff.compactMap(\.newLine).max() ?? 0)
        let numWidth = max(36, textWidth(String(maxLine)) + 18)
        let available = diffScroll.contentSize.width
        switch diffMode {
        case .combined:
            let widest = min(parsedDiff.map { textWidth($0.text) }.max() ?? 100, 3000)
            setWidth("oldNo", numWidth)
            setWidth("newNo", numWidth)
            setWidth("mark", 20)
            setWidth("text", max(widest + 20, available - numWidth * 2 - 20))
        case .split:
            let oldWidest = min(splitDiff.map { textWidth($0.oldText) }.max() ?? 80, 1500)
            let newWidest = min(splitDiff.map { textWidth($0.newText) }.max() ?? 80, 1500)
            let share = max((available - numWidth * 2) / 2, 80)
            setWidth("oldNo", numWidth)
            setWidth("oldText", max(oldWidest + 20, share))
            setWidth("newNo", numWidth)
            setWidth("newText", max(newWidest + 20, share))
        }
    }

    private func diffTint(for kind: DiffLine.Kind?) -> NSColor? {
        switch kind {
        case .add: return Self.diffAddColor.withAlphaComponent(0.13)
        case .del: return Self.diffDelColor.withAlphaComponent(0.13)
        case .hunk: return Self.diffHunkColor.withAlphaComponent(0.08)
        default: return nil
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        diffMode == .combined ? parsedDiff.count : splitDiff.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }
        let id = tableColumn.identifier.rawValue
        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil)
            as? DiffCellView ?? DiffCellView()
        cell.identifier = tableColumn.identifier
        if cell.textField == nil {
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byClipping
            cell.addSubview(textField)
            textField.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(
                    lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.textField = textField
        }
        let textField = cell.textField!
        textField.font = diffMonoFont()
        textField.textColor = .labelColor
        textField.alignment = id.hasPrefix("oldNo") || id.hasPrefix("newNo") ? .right : .left

        func setNumber(_ value: Int?, _ kind: DiffLine.Kind?) {
            textField.stringValue = value.map(String.init) ?? ""
            textField.textColor = .secondaryLabelColor
            cell.tint = diffTint(for: kind)
        }
        func setContent(_ text: String, _ kind: DiffLine.Kind?) {
            textField.stringValue = text
            cell.tint = diffTint(for: kind)
            if kind == .hunk { textField.textColor = Self.diffHunkColor }
        }

        if diffMode == .combined {
            guard row < parsedDiff.count else { return nil }
            let line = parsedDiff[row]
            switch id {
            case "oldNo": setNumber(line.oldLine, line.kind)
            case "newNo": setNumber(line.newLine, line.kind)
            case "mark":
                textField.alignment = .center
                switch line.kind {
                case .add:
                    textField.stringValue = "+"
                    textField.textColor = Self.diffAddColor
                case .del:
                    textField.stringValue = "−"
                    textField.textColor = Self.diffDelColor
                default:
                    textField.stringValue = ""
                }
                cell.tint = diffTint(for: line.kind)
            default: setContent(line.text, line.kind)
            }
        } else {
            guard row < splitDiff.count else { return nil }
            let splitRow = splitDiff[row]
            switch id {
            case "oldNo": setNumber(splitRow.oldLine, splitRow.oldKind)
            case "oldText": setContent(splitRow.oldText, splitRow.oldKind)
            case "newNo": setNumber(splitRow.newLine, splitRow.newKind)
            default: setContent(splitRow.newText, splitRow.newKind)
            }
        }
        return cell
    }

    // MARK: - preview

    private static let maxPreviewBytes = 1_000_000

    private func previewFont() -> NSFont {
        if let name = config.fontName, let f = NSFont(name: name, size: config.fontSize) {
            return f
        }
        return .monospacedSystemFont(ofSize: config.fontSize, weight: .regular)
    }

    private func clearPreview() {
        previewedURL = nil
        previewRaw = nil
        showingDiff = false
        updateDiffChrome()
        previewTitle.stringValue = ""
        updateMarkdownToggle()
        textView.string = ""
    }

    private func showPlaceholder(_ text: String) {
        showingDiff = false
        updateDiffChrome()
        textView.string = ""
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: config.fontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        textView.textStorage?.append(NSAttributedString(string: text, attributes: attrs))
    }

    private func loadPreview(for url: URL) {
        let path = url.path
        guard let handle = FileHandle(forReadingAtPath: path) else {
            showPlaceholder("Cannot read \(url.lastPathComponent)")
            return
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else {
            clearPreview()
            return
        }
        guard size <= Self.maxPreviewBytes else {
            showPlaceholder("\(url.lastPathComponent) is too large to preview (\(size / 1_000_000) MB)")
            return
        }
        try? handle.seek(toOffset: 0)
        let data = handle.readDataToEndOfFile()
        // NUL in the first chunk ⇒ treat as binary.
        if data.prefix(8192).contains(0) {
            showPlaceholder("\(url.lastPathComponent): binary file")
            return
        }
        guard let string = String(data: data, encoding: .utf8) else {
            showPlaceholder("\(url.lastPathComponent): not UTF-8 text")
            return
        }
        previewedURL = url
        previewRaw = string
        showingDiff = false
        updateDiffChrome()
        previewTitle.stringValue = url.lastPathComponent
        updateMarkdownToggle()
        renderPreview()
    }

    private func renderPreview() {
        guard let raw = previewRaw, let url = previewedURL else { return }
        let ext = url.pathExtension.lowercased()
        if (ext == "md" || ext == "markdown"), markdownRendered {
            let width = textView.enclosingScrollView?.contentSize.width ?? 300
            textView.textStorage?.setAttributedString(
                MarkdownRender.attributed(raw, width: width))
        } else {
            let styled = NSMutableAttributedString(string: raw, attributes: [
                .font: previewFont(),
                .foregroundColor: NSColor.textColor,
            ])
            CodeHighlighter.highlight(styled, ext: ext)
            textView.textStorage?.setAttributedString(styled)
        }
        textView.scrollToBeginningOfDocument(nil)
    }

    private func updateMarkdownToggle() {
        let isMarkdown = previewedURL.map {
            ["md", "markdown"].contains($0.pathExtension.lowercased())
        } ?? false
        // The Stage button owns the trailing slot when a change is selected.
        markdownToggle.isHidden = !isMarkdown || selectedChange != nil
        markdownToggle.setSelectedIndex(markdownRendered ? 0 : 1)
    }

    @objc private func refreshTapped(_ sender: Any?) {
        switch page {
        case .files:
            let query = searchField.stringValue
            fileListCache = nil
            rootPath = nil // force reRoot even if the path is unchanged
            reRoot(session?.currentDirectory() ?? rootPathBeforeReset())
            if !query.isEmpty {
                searchField.stringValue = query
                applySearch()
            }
        case .changes:
            refreshChanges()
        case .chat:
            break
        }
    }

    private func rootPathBeforeReset() -> String? {
        // refreshTapped nils rootPath first; recover the displayed path so a
        // dead session still refreshes the visible folder.
        (pathLabel.stringValue as NSString).expandingTildeInPath
    }

    // MARK: - outline data source / delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? CodeFileNode { return node.children.count }
        guard item == nil else { return 0 }
        switch page {
        case .changes: return changes.count
        case .files:
            if let results = searchResults { return results.count }
            return root?.children.count ?? 0
        case .chat: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? CodeFileNode { return node.children[index] }
        switch page {
        case .changes: return changes[index]
        case .files:
            if let results = searchResults { return results[index] }
            return root!.children[index]
        case .chat: preconditionFailure("CHAT has no outline children")
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard page == .files, searchResults == nil else { return false }
        return (item as? CodeFileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        CodeRowView()
    }

    private func statusColor(_ change: CodeChange) -> NSColor {
        switch change.label {
        case "A", "??": return Self.diffAddColor
        case "D": return Self.diffDelColor
        case "R": return .systemBlue
        default: return NSColor(
            calibratedRed: 0xE5 / 255, green: 0xC0 / 255, blue: 0x7B / 255, alpha: 1)
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("fileCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? CodeTableCellView
            ?? CodeTableCellView()
        cell.identifier = id
        if cell.imageView == nil {
            let imageView = NSImageView()
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.addSubview(cell.badge)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.badge.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                cell.badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                cell.badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                cell.badge.widthAnchor.constraint(equalToConstant: 20),
                cell.badge.heightAnchor.constraint(equalToConstant: 14),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.badge.leadingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.imageView = imageView
            cell.textField = textField
        }

        if let change = item as? CodeChange {
            let color = statusColor(change)
            cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
            cell.textField?.textColor = .labelColor
            cell.textField?.stringValue = change.path
            cell.badge.stringValue = change.label
            // Staged rows get a solid badge so staging one file — or Stage
            // All — is visible at a glance; unstaged stays tinted.
            if change.isStaged {
                cell.badge.textColor = NSColor(calibratedWhite: 0.08, alpha: 1)
                cell.badge.layer?.backgroundColor = color.cgColor
            } else {
                cell.badge.textColor = color
                cell.badge.layer?.backgroundColor = color.withAlphaComponent(0.22).cgColor
            }
            cell.badge.isHidden = false
            cell.imageView?.image = CodeIcon.image(
                for: URL(fileURLWithPath: change.path), isDirectory: false)
            return cell
        }

        guard let node = item as? CodeFileNode else { return nil }
        cell.badge.isHidden = true
        cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
        cell.textField?.textColor = .labelColor
        cell.textField?.stringValue = node.nameOverride ?? node.url.lastPathComponent
        cell.imageView?.image = CodeIcon.image(
            for: node.url, isDirectory: node.isDirectory)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) else { return }
        if let change = item as? CodeChange {
            selectedChange = change
            updateStageButton()
            previewChange(change)
            return
        }
        selectedChange = nil
        updateStageButton()
        guard let node = item as? CodeFileNode, !node.isDirectory else { return }
        loadPreview(for: node.url)
    }

    // MARK: - test seams

    var topLevelRowCountForTesting: Int { outlineView.numberOfRows }
    var previewTextForTesting: String { textView.string }
    var pageControlLabelsForTesting: [String] { pageControl.labelsForTesting }
    var pageControlFontSizeForTesting: CGFloat { pageControl.fontSizeForTesting }
    var searchFontSizeForTesting: CGFloat { searchField.font?.pointSize ?? 0 }
    func cellFontSizeForTesting(row: Int) -> CGFloat {
        (outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? CodeTableCellView)?.textField?.font?.pointSize ?? 0
    }
    func cellIconSizeForTesting(row: Int) -> CGFloat {
        (outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? CodeTableCellView)?.imageView?.image?.size.width ?? 0
    }
    var pageControlFontWeightForTesting: CGFloat { pageControl.fontWeightForTesting }
    var pageControlHasOutlineForTesting: Bool {
        pageControl.outlineColor.alphaComponent > 0
    }
    var fileIconSizeForTesting: NSSize {
        CodeIcon.image(for: URL(fileURLWithPath: "file.swift"), isDirectory: false)?.size ?? .zero
    }
    var searchCornerRadiusForTesting: CGFloat { searchField.layer?.cornerRadius ?? 0 }
    var pageControlSelectionIsNeutralForTesting: Bool {
        CodePalette.isNeutral(pageControl.selectionFillColor)
    }
    var rowSelectionIsNeutralForTesting: Bool {
        CodePalette.isNeutral(CodeRowView.emphasizedSelectionColor)
    }
    var diffModeSelectionIsNeutralForTesting: Bool {
        CodePalette.isNeutral(unifiedButton.contentTintColor ?? .clear)
            && CodePalette.isNeutral(splitDiffButton.contentTintColor ?? .clear)
    }
    var chatPageIsVisibleForTesting: Bool { !chatHost.isHidden }
    var chatPageFrameForTesting: NSRect { chatHost.frame }
    func chatPageUsesAssistantForTesting(_ assistant: PetAssistant) -> Bool {
        self.assistant === assistant
    }
    var headerTextForTesting: String { pathLabel.stringValue }
    var previewTitleForTesting: String { previewTitle.stringValue }
    var markdownToggleHiddenForTesting: Bool { markdownToggle.isHidden }
    var pageControlFrameForTesting: NSRect { pageControl.frame }
    var branchFooterTextForTesting: String? {
        branchFooter.isHidden ? nil : branchButton.title
    }
    var stageButtonHiddenForTesting: Bool { stageButton.isHidden }
    var stageButtonTitleForTesting: String { stageButton.title }
    var stageAllButtonHiddenForTesting: Bool { stageAllButton.isHidden }
    func selectRowForTesting(_ row: Int) {
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    func stageSelectedForTesting() { stageTapped(nil) }
    func stageAllForTesting() { stageAllTapped(nil) }
    var commitButtonEnabledForTesting: Bool { commitButton.isEnabled }
    var commitMessageForTesting: String { commitField.stringValue }
    func setCommitMessageForTesting(_ text: String) {
        commitField.stringValue = text
        updateCommitControls()
    }
    func commitForTesting() { commitTapped(nil) }
    var showingDiffForTesting: Bool { showingDiff }
    var diffModeForTesting: Int { diffMode == .combined ? 0 : 1 }
    var diffFontSizeForTesting: CGFloat { diffFontSize }
    var diffRowCountForTesting: Int { numberOfRows(in: diffTable) }
    func setDiffModeForTesting(_ index: Int) { setDiffMode(index == 0 ? .combined : .split) }
    func adjustDiffFontForTesting(_ delta: CGFloat) { adjustDiffFont(delta) }
    func showDiffForTesting(_ diff: String) { showDiff(diff) }
    func diffCellTextForTesting(row: Int, column: Int) -> String? {
        guard row >= 0, row < numberOfRows(in: diffTable),
              column >= 0, column < diffTable.tableColumns.count else { return nil }
        let cell = tableView(diffTable, viewFor: diffTable.tableColumns[column], row: row)
            as? NSTableCellView
        return cell?.textField?.stringValue
    }
    var statCountsForTesting: [Int] { statCountFields.map { Int($0.stringValue) ?? 0 } }
    func reRootForTesting(_ path: String) { reRoot(path) }
    func loadPreviewForTesting(_ url: URL) { loadPreview(for: url) }
    func setMarkdownRenderedForTesting(_ rendered: Bool) {
        markdownRendered = rendered
        renderPreview()
        updateMarkdownToggle()
    }
    func setSearchTextForTesting(_ text: String) { searchField.stringValue = text }
    func seedFileListCacheForTesting(_ paths: [String]) { fileListCache = paths }
    func applySearchForTesting() { applySearch() }
    func switchPageForTesting(_ index: Int) {
        pageControl.setSelectedIndex(index, notify: true)
    }
    func applyChangesForTesting(repo: String?, branch: String?, changes: [CodeChange]) {
        applyChanges(
            CodeGit.RepoStatus(branch: branch, changes: changes, error: nil),
            repo: repo, root: rootPath ?? "")
    }
    func rectOfFirstRowForTesting() -> NSRect {
        outlineView.numberOfRows > 0 ? outlineView.rect(ofRow: 0) : .zero
    }
    func cellTextForTesting(row: Int) -> String? {
        guard let item = outlineView.item(atRow: row) else { return nil }
        let cell = outlineView(self.outlineView, viewFor: nil, item: item)
            as? NSTableCellView
        return cell?.textField?.stringValue
    }
    func cellBadgeForTesting(row: Int) -> String? {
        guard let item = outlineView.item(atRow: row) else { return nil }
        let cell = outlineView(self.outlineView, viewFor: nil, item: item)
            as? CodeTableCellView
        return cell?.badge.isHidden == false ? cell?.badge.stringValue : nil
    }
    func cellBadgeIsSolidForTesting(row: Int) -> Bool {
        guard let item = outlineView.item(atRow: row) else { return false }
        let cell = outlineView(self.outlineView, viewFor: nil, item: item)
            as? CodeTableCellView
        guard let bg = cell?.badge.layer?.backgroundColor,
              let color = NSColor(cgColor: bg) else { return false }
        return color.alphaComponent == 1
    }
    func layoutSummaryForTesting() -> String {
        let split = view.subviews.compactMap { $0 as? NSSplitView }.first
        let tree = split?.arrangedSubviews.first
        let preview = split?.arrangedSubviews.last
        let row0 = outlineView.numberOfRows > 0
            ? outlineView.rect(ofRow: 0) : .zero
        return "sidebar=\(view.frame) inner=\(split?.frame ?? .zero) "
            + "tree=\(tree?.frame ?? .zero) preview=\(preview?.frame ?? .zero) "
            + "rows=\(outlineView.numberOfRows) row0=\(row0)"
    }
    func treeHeightForTesting() -> CGFloat {
        view.subviews.compactMap { $0 as? NSSplitView }.first?
            .arrangedSubviews.first?.frame.height ?? 0
    }
}
