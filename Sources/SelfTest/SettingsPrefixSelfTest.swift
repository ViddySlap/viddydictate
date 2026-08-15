import Cocoa

/// Pure characterization for the Settings control-identifier prefix parsers.
enum SettingsPrefixSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate settings identifier prefixes - selftest ===")
        let reporter = SelfTestReporter()

        checkIdentifierSuffix(reporter: reporter)
        checkProvider(reporter: reporter)
        checkRoute(reporter: reporter)
        checkOwnerKey(reporter: reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "Settings identifier prefixes"))
        return reporter.passed
    }

    private static func checkIdentifierSuffix(reporter: SelfTestReporter) {
        let control = NSControl(frame: .zero)

        control.identifier = NSUserInterfaceItemIdentifier("provider|cleanup")
        reporter.record(
            "identifierSuffix accepts a matching non-empty suffix",
            ModelsPowerSettingsView.identifierSuffix(control, prefix: "provider|") == "cleanup"
        )

        control.identifier = NSUserInterfaceItemIdentifier("advanced|cleanup")
        reporter.record(
            "identifierSuffix rejects an unknown prefix",
            ModelsPowerSettingsView.identifierSuffix(control, prefix: "provider|") == nil
        )

        control.identifier = NSUserInterfaceItemIdentifier("provider|")
        reporter.record(
            "identifierSuffix rejects an empty suffix",
            ModelsPowerSettingsView.identifierSuffix(control, prefix: "provider|") == nil
        )
    }

    private static func checkProvider(reporter: SelfTestReporter) {
        let control = NSControl(frame: .zero)

        control.identifier = NSUserInterfaceItemIdentifier("bulk|codex")
        reporter.record(
            "providerFrom accepts a matching known provider",
            ModelsPowerSettingsView.providerFrom(control.identifier, prefix: "bulk|") == .codex
        )

        control.identifier = NSUserInterfaceItemIdentifier("provider|codex")
        reporter.record(
            "providerFrom rejects an unknown prefix",
            ModelsPowerSettingsView.providerFrom(control.identifier, prefix: "bulk|") == nil
        )

        control.identifier = NSUserInterfaceItemIdentifier("bulk|")
        reporter.record(
            "providerFrom rejects an empty suffix",
            ModelsPowerSettingsView.providerFrom(control.identifier, prefix: "bulk|") == nil
        )
    }

    private static func checkRoute(reporter: SelfTestReporter) {
        let control = NSControl(frame: .zero)

        control.identifier = NSUserInterfaceItemIdentifier("model|cleanupL1")
        reporter.record(
            "routeFrom accepts a matching known route",
            ModelsPowerSettingsView.routeFrom(control.identifier, prefix: "model|") == .cleanupL1
        )

        control.identifier = NSUserInterfaceItemIdentifier("effort|cleanupL1")
        reporter.record(
            "routeFrom rejects an unknown prefix",
            ModelsPowerSettingsView.routeFrom(control.identifier, prefix: "model|") == nil
        )

        control.identifier = NSUserInterfaceItemIdentifier("model|")
        reporter.record(
            "routeFrom rejects an empty suffix",
            ModelsPowerSettingsView.routeFrom(control.identifier, prefix: "model|") == nil
        )
    }

    private static func checkOwnerKey(reporter: SelfTestReporter) {
        let control = NSControl(frame: .zero)

        control.identifier = NSUserInterfaceItemIdentifier("input|custom:abc")
        reporter.record(
            "ownerKeyFrom accepts a matching non-empty suffix",
            HotkeysSettingsView.ownerKeyFrom(control, prefix: "input|") == "custom:abc"
        )

        control.identifier = NSUserInterfaceItemIdentifier("landing|custom:abc")
        reporter.record(
            "ownerKeyFrom rejects an unknown prefix",
            HotkeysSettingsView.ownerKeyFrom(control, prefix: "input|") == nil
        )

        control.identifier = NSUserInterfaceItemIdentifier("input|")
        reporter.record(
            "ownerKeyFrom rejects an empty suffix",
            HotkeysSettingsView.ownerKeyFrom(control, prefix: "input|") == nil
        )
    }
}
