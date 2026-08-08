import AppKit

/// Font-family lists shared by the modern and legacy settings surfaces.
enum SystemFontCatalog {
    static let allFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
    }()

    static let monospacedFamilies: [String] = allFamilies.filter(isMonospacedFamily)

    static func options(
        defaultLabel: String,
        configured: String?,
        monospacedOnly: Bool
    ) -> [(value: String, label: String)] {
        let families = monospacedOnly ? monospacedFamilies : allFamilies
        var options: [(value: String, label: String)] = [("", defaultLabel)]
        for family in families {
            options.append((family, family))
        }
        if let configured,
           !configured.isEmpty,
           !options.contains(where: { $0.value.caseInsensitiveCompare(configured) == .orderedSame }),
           (!monospacedOnly || isMonospacedFamily(configured)) {
            options.insert((configured, configured), at: 1)
        }
        return options
    }

    static func isMonospacedFamily(_ family: String) -> Bool {
        guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family),
              let postScriptName = members.compactMap({
                  $0.count > 0 ? $0[0] as? String : nil
              }).first,
              let font = NSFont(name: postScriptName, size: 12)
        else { return false }

        let traits = font.fontDescriptor.symbolicTraits
        return traits.contains(.monoSpace)
            || NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask)
    }
}
