import Foundation

/// The Python interpreter ViddyDictate ships INSIDE its own app bundle.
///
/// macOS has no usable system Python: `/usr/bin/python3` is a Command-Line-Tools stub that prompts
/// rather than runs. Both environments the app depends on — the STT daemon venv and the web-search
/// helper venv — therefore have to be built by an interpreter the app brought with it, because the
/// person who dragged the app across from a DMG has no repository to run an installer script from.
/// That is the whole reason this type exists; the alternative is the app's own error text telling a
/// stranger to run a script they do not have.
///
/// Spec B3, and it is a promise the first-run picker makes to the user in words rather than an
/// implementation detail: the runtime lives in the bundle, nothing lands in `/usr/local`, nothing
/// runs at login, and deleting the app deletes it. Nothing here may grow a fallback that reaches for
/// a system, Homebrew, or `PATH` interpreter — a silent fallback would make the picker's wording a
/// lie on exactly the machines where it matters.
///
/// `build.sh` stages the runtime and signs every Mach-O in it with the hardened runtime; the paths
/// below are the other half of that contract, so the two are kept adjacent on purpose.
enum BundledPython {
    /// The interpreter series `build.sh` pins. Asserted against the real binary by
    /// `--bundled-python-selftest`, so the pin and the bundle cannot drift apart quietly.
    static let seriesVersion = "3.12"

    /// The runtime's location inside a bundle, written once. `build.sh`, this accessor and the
    /// self-test all have to agree on it, and three copies of the same relative path is how they
    /// stop agreeing.
    static let bundleRelativePath = "Contents/Resources/python"

    /// The interpreter is reached through `bin/python3`, the distribution's own symlink, rather than
    /// through the versioned name: a Python bump then changes one pinned string in `build.sh` and
    /// nothing here.
    private static let interpreterRelativePath = "bin/python3"

    static func runtimeRoot(inBundleAt bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(bundleRelativePath, isDirectory: true)
    }

    static func interpreter(inBundleAt bundleURL: URL) -> URL {
        runtimeRoot(inBundleAt: bundleURL)
            .appendingPathComponent(interpreterRelativePath, isDirectory: false)
    }

    static func isInstalled(inBundleAt bundleURL: URL, fileManager fm: FileManager = .default) -> Bool {
        fm.isExecutableFile(atPath: interpreter(inBundleAt: bundleURL).path)
    }

    /// The running app's own interpreter. Built from `bundleURL` rather than `resourceURL` so the
    /// running bundle and a bundle under test are resolved by the same arithmetic.
    static var interpreterURL: URL { interpreter(inBundleAt: Bundle.main.bundleURL) }

    static var runtimeRootURL: URL { runtimeRoot(inBundleAt: Bundle.main.bundleURL) }

    static var isInstalled: Bool { isInstalled(inBundleAt: Bundle.main.bundleURL) }
}
