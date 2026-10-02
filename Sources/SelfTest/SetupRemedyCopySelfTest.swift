import Foundation

/// The install remedy must name a button the Setup tab really has.
///
/// Until 2026-10-01 `BootstrapInstallPlan.installPrompt` told users to "choose Install now" in Settings >
/// Setup, a button that tab never had for the core rows. Its real entry point is the first-run setup
/// re-open button, `FirstRunSetupPresenter.rerunTitle`, whose Continue always queues the mandatory core.
///
/// Pure: the prompt strings, the two callers that quote them, and a read of `SetupSettingsView.swift` for the
/// button built from that constant. The on-screen button and its click are photographed by --setup-render.
/// The negative control runs the old wording through the same predicate and requires it to fail.
enum SetupRemedyCopySelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate Setup install-remedy copy selftest ===")
        let reporter = SelfTestReporter()
        let check = reporter.check
        let rerun = FirstRunSetupPresenter.rerunTitle

        print("--- the prompt names the real button, for every component it is used for ---")
        for component in [BootstrapInstallPlan.sttDaemon, BootstrapInstallPlan.webSearch] {
            let prompt = BootstrapInstallPlan.installPrompt(for: component)
            check("\(component.title): names the Setup tab's real button (\(rerun))",
                  namesRealSetupButton(prompt, title: component.title))
            check("\(component.title): never says Install now", !prompt.contains("Install now"))
            check("\(component.title): is mandatory core, which first-run setup always queues",
                  BootstrapInstallPlan.mandatoryCore.contains { $0.id == component.id })
            print("    \(prompt)")
        }

        print("--- the callers quote it ---")
        check("the web-search missing-backend message carries the real button",
              SearchClient.missingLocalBackendMessage.contains(rerun)
                && !SearchClient.missingLocalBackendMessage.contains("Install now"))

        print("--- the Setup tab builds a button with that title ---")
        if let root = repositoryRoot() {
            let view = (try? String(contentsOf: root.appendingPathComponent(
                "Sources/App/SetupSettingsView.swift"), encoding: .utf8)) ?? ""
            check("SetupSettingsView builds an NSButton titled FirstRunSetupPresenter.rerunTitle",
                  view.contains("NSButton(title: FirstRunSetupPresenter.rerunTitle"))
            check("the Setup tab has no Install now button for the core to send anyone to",
                  !view.contains("\"Install now\""))
        } else {
            reporter.record("the repository root is reachable from the test bundle path", false,
                            Bundle.main.bundleURL.path)
        }

        print("--- negative control: the old wording ---")
        let old = "open Settings > Setup and choose Install now for \(BootstrapInstallPlan.webSearch.title)"
        check("the old 'choose Install now' prompt fails the real-button check",
              !namesRealSetupButton(old, title: BootstrapInstallPlan.webSearch.title))

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "setup-remedy-copy"))
        return reporter.passed
    }

    /// The one predicate both the real prompt and the negative control go through.
    private static func namesRealSetupButton(_ prompt: String, title: String) -> Bool {
        prompt.contains("Settings > Setup") && prompt.contains(FirstRunSetupPresenter.rerunTitle)
            && prompt.contains(title) && !prompt.contains("Install now")
    }

    /// Walks up from `<repo>/build/ViddyDictateTests.app` to the directory holding the daemon script, as
    /// `DaemonInstallSelfTest` does. A missing root is a recorded failure, never a crash.
    private static func repositoryRoot() -> URL? {
        let fm = FileManager.default
        var directory = Bundle.main.bundleURL
        for _ in 0..<12 {
            if fm.fileExists(atPath: directory.appendingPathComponent("viddydictate_whisperd.py").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }
}
