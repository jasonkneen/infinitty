import AppKit

/// SF Symbol icons for the code-view tree, keyed off file type. Folders get
/// a blue tint; files stay monochrome so the list doesn't turn into confetti.
enum CodeIcon {

    private static let codeExts: Set<String> = [
        "swift", "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "go", "rs",
        "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "cs", "rb",
        "sh", "zsh", "bash", "css", "scss", "html", "htm", "vue", "svelte",
    ]
    private static let dataExts: Set<String> = [
        "json", "yaml", "yml", "toml", "xml", "plist", "csv",
    ]
    private static let docExts: Set<String> = [
        "md", "markdown", "txt", "rst", "pdf",
    ]
    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "icns", "ico", "svg", "webp", "heic",
    ]
    private static let archiveExts: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "xz", "dmg", "pkg", "7z",
    ]

    static func symbolName(for url: URL, isDirectory: Bool) -> String {
        if isDirectory { return "folder.fill" }
        let ext = url.pathExtension.lowercased()
        if ext == "swift" { return "swift" }
        if codeExts.contains(ext) { return "chevron.left.slash.chevron" }
        if dataExts.contains(ext) { return "curlybraces" }
        if docExts.contains(ext) { return "doc.richtext" }
        if imageExts.contains(ext) { return "photo" }
        if archiveExts.contains(ext) { return "doc.zipper" }
        return "doc"
    }

    static func image(for url: URL, isDirectory: Bool) -> NSImage? {
        let name = symbolName(for: url, isDirectory: isDirectory)
        let color: NSColor = isDirectory ? .systemBlue : .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(hierarchicalColor: color)
        let image = NSImage(
            systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.size = NSSize(width: 14, height: 14)
        return image
    }
}
