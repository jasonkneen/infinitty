import Foundation

/// Anchor for `Bundle(for:)` so the resource bundle can be found relative to
/// this module's own location, the way SwiftPM's generated accessor does.
private final class BundleFinder {}

extension Bundle {
    /// The SwiftPM resource bundle, or nil when it isn't present.
    ///
    /// SwiftPM's generated `Bundle.module` **traps** (`fatalError`) when the
    /// bundle can't be found, and `scripts/make-app.sh` copies the resource
    /// *directories* (Logos, Pets, Surfaces) straight into
    /// `Contents/Resources` without ever copying
    /// `infinitty_InfinittyKit.bundle`. So in a packaged app every
    /// `Bundle.module` access is a landmine: it only detonates on the code
    /// path where `Bundle.main` misses first — which is exactly the fallback
    /// path that exists to handle a missing asset gracefully.
    ///
    /// That is what killed the app on opening chat: there is no `hermes.svg`,
    /// so the Hermes row fell past `Bundle.main` into `Bundle.module` and
    /// trapped, instead of reaching the SF Symbol fallback below it.
    ///
    /// This looks the bundle up by hand and returns nil rather than trapping,
    /// so a missing asset degrades to whatever fallback the caller already
    /// wrote.
    static let infinittyResources: Bundle? = {
        let name = "infinitty_InfinittyKit.bundle"
        // Mirrors SwiftPM's own generated search order, plus the sibling-of-
        // the-test-bundle case, but answers nil instead of trapping.
        let own = Bundle(for: BundleFinder.self)
        let directories: [URL?] = [
            Bundle.main.resourceURL,
            own.resourceURL,
            Bundle.main.bundleURL,
            own.bundleURL.deletingLastPathComponent(),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
        ]
        for case let directory? in directories {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }()

    /// Find a resource in the app bundle first, then the SwiftPM bundle.
    /// Never traps.
    static func infinittyResourceURL(
        forResource resource: String,
        withExtension ext: String,
        subdirectory: String? = nil
    ) -> URL? {
        if let subdirectory,
           let url = Bundle.main.url(
               forResource: resource, withExtension: ext, subdirectory: subdirectory) {
            return url
        }
        if let url = Bundle.main.url(forResource: resource, withExtension: ext) {
            return url
        }
        if let subdirectory,
           let url = infinittyResources?.url(
               forResource: resource, withExtension: ext, subdirectory: subdirectory) {
            return url
        }
        return infinittyResources?.url(forResource: resource, withExtension: ext)
    }
}
