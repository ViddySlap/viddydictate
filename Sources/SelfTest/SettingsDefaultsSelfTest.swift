import Foundation

/// Pure synthetic coverage for defaults whose fallback behavior must not overwrite stored preferences.
enum SettingsDefaultsSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate settings defaults and stored preferences - selftest ===")
        let reporter = SelfTestReporter()
        let expectedDefault = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
        let storedPreference = "/synthetic/custom-notes"

        reporter.record(
            "sticky notes default save directory is Documents",
            Settings.defaultStickyNotesSaveDirectory == expectedDefault
        )
        reporter.record(
            "missing sticky notes preference falls back to the default",
            Settings.resolvedStickyNotesSaveDirectory(storedPath: nil) == expectedDefault.path
        )
        reporter.record(
            "empty sticky notes preference falls back to the default",
            Settings.resolvedStickyNotesSaveDirectory(storedPath: "") == expectedDefault.path
        )
        reporter.record(
            "non-empty sticky notes preference is preserved",
            Settings.resolvedStickyNotesSaveDirectory(storedPath: storedPreference) == storedPreference
        )
        reporter.record(
            "recent dictation audio retention defaults on for future debugging",
            Settings.retainDictationAudio
        )
        checkBundleIdentifierMigration(reporter)
        checkLaunchAgentIdentity(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "Settings defaults"))
        return reporter.passed
    }

    private static func checkBundleIdentifierMigration(_ reporter: SelfTestReporter) {
        print("--- bundle identifier defaults migration ---")
        let token = UUID().uuidString
        let legacyDomain = "test.viddydictate.legacy.\(token)"
        let currentDomain = "test.viddydictate.current.\(token)"
        guard let defaults = UserDefaults(suiteName: currentDomain) else {
            reporter.record("synthetic defaults suite opens", false)
            return
        }
        defer {
            defaults.removePersistentDomain(forName: legacyDomain)
            defaults.removePersistentDomain(forName: currentDomain)
        }

        defaults.setPersistentDomain([
            "hotkeyMap": "legacy-hotkeys",
            "powerMode": "finalOnly",
            "cloudPresetEnabled": true,
        ], forName: legacyDomain)
        defaults.setPersistentDomain([
            "powerMode": "live",
            "newDomainOnly": "keep-me",
        ], forName: currentDomain)

        Settings.migrateLegacyDefaultsDomainIfNeeded(
            defaults: defaults,
            currentDomain: currentDomain,
            legacyDomain: legacyDomain,
            expectedCurrentDomain: currentDomain)
        let migrated = defaults.persistentDomain(forName: currentDomain) ?? [:]
        reporter.record(
            "legacy preferences copy into the new bundle domain",
            migrated["hotkeyMap"] as? String == "legacy-hotkeys"
                && migrated["cloudPresetEnabled"] as? Bool == true)
        reporter.record(
            "existing new-domain preferences win over legacy values",
            migrated["powerMode"] as? String == "live"
                && migrated["newDomainOnly"] as? String == "keep-me")
        reporter.record(
            "defaults migration records its one-time guard",
            migrated[Settings.legacyDefaultsMigrationMarker] as? Bool == true)

        defaults.setPersistentDomain([
            "hotkeyMap": "changed-after-migration",
        ], forName: legacyDomain)
        Settings.migrateLegacyDefaultsDomainIfNeeded(
            defaults: defaults,
            currentDomain: currentDomain,
            legacyDomain: legacyDomain,
            expectedCurrentDomain: currentDomain)
        let guarded = defaults.persistentDomain(forName: currentDomain) ?? [:]
        reporter.record(
            "the one-time guard prevents a later legacy overwrite",
            guarded["hotkeyMap"] as? String == "legacy-hotkeys"
                && guarded["powerMode"] as? String == "live")

        let unrelatedDomain = "test.viddydictate.unrelated.\(token)"
        defer { defaults.removePersistentDomain(forName: unrelatedDomain) }
        Settings.migrateLegacyDefaultsDomainIfNeeded(
            defaults: defaults,
            currentDomain: unrelatedDomain,
            legacyDomain: legacyDomain,
            expectedCurrentDomain: currentDomain)
        reporter.record(
            "non-shipping bundle domains never import production preferences",
            defaults.persistentDomain(forName: unrelatedDomain) == nil)
    }

    private static func checkLaunchAgentIdentity(_ reporter: SelfTestReporter) {
        print("--- bundle and LaunchAgent identities ---")
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appPlist = root.appendingPathComponent("com.viddydictate.app.plist")
        let daemonPlist = root.appendingPathComponent("com.viddydictate.whisperd.plist")

        reporter.record("shipping bundle identifier is handle-free",
                        AppIdentity.bundleID == "com.viddydictate.app")
        reporter.record("Application Support keeps the ViddyDictate folder",
                        AppPaths.applicationSupportDirectory().lastPathComponent == "ViddyDictate")
        reporter.record("renamed app LaunchAgent plist exists", FileManager.default.fileExists(atPath: appPlist.path))
        reporter.record("renamed daemon LaunchAgent plist exists",
                        FileManager.default.fileExists(atPath: daemonPlist.path))
        let launchAgentPlists = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix("com.") && $0.hasSuffix(".plist") }
        reporter.record("only current LaunchAgent plist names ship",
                        Set(launchAgentPlists) == Set([
                            "com.viddydictate.app.plist",
                            "com.viddydictate.whisperd.plist",
                        ]))

        reporter.record("app plist Label matches the new bundle identifier",
                        plistLabel(appPlist) == AppIdentity.bundleID)
        reporter.record("daemon plist Label is handle-free",
                        plistLabel(daemonPlist) == DaemonClient.agentLabel)
        checkInstallerOrder(
            reporter,
            root: root,
            filename: "install-app-agent.sh",
            legacyLabel: AppIdentity.legacyBundleID,
            newLabel: AppIdentity.bundleID)
        checkDaemonArtifactNaming(reporter, root: root, daemonPlist: daemonPlist)
        checkDaemonDocMatchesTheLiveLabel(reporter, root: root)
    }

    private static func checkDaemonArtifactNaming(_ reporter: SelfTestReporter,
                                                  root: URL,
                                                  daemonPlist: URL) {
        let installer = (try? String(
            contentsOf: root.appendingPathComponent("install-daemon.sh"), encoding: .utf8)) ?? ""
        let plist = (try? String(contentsOf: daemonPlist, encoding: .utf8)) ?? ""

        reporter.record("daemon installer uses the public source and destination name",
                        installer.contains("SRC=\"$ROOT/viddydictate_whisperd.py\"")
                            && installer.contains("DEST=\"$SUPPORT/viddydictate_whisperd.py\""))
        reporter.record("daemon installer uses the public port variable without changing its default",
                        installer.contains("PORT=\"${VIDDYDICTATE_WHISPER_PORT:-8765}\""))
        reporter.record("daemon installer carries no legacy-label migration shim",
                        !installer.contains("OLD_LABEL=") && !installer.contains("OLD_PLIST_DST="))
        reporter.record("daemon plist uses the public filename and environment prefix",
                        plist.contains("/ViddyDictate/viddydictate_whisperd.py")
                            && plist.contains("<key>VIDDYDICTATE_WHISPER_PORT</key>")
                            && plist.contains("<string>8765</string>"))
        reporter.record("daemon plist uses the public log paths",
                        plist.contains("/tmp/viddydictate-whisperd.out.log")
                            && plist.contains("/tmp/viddydictate-whisperd.err.log"))
    }

    /// The rename has to reach the prose a stranger reads, not just the code. `docs/stt-daemon.md`
    /// went on stating that the label "keeps its `com.lifeos.` prefix ... renaming it is a separate,
    /// app-side change" after that rename had already shipped, which sends a new user hunting for an
    /// agent that no longer exists and re-publishes the old private prefix as a current fact.
    private static func checkDaemonDocMatchesTheLiveLabel(_ reporter: SelfTestReporter, root: URL) {
        let doc = (try? String(
            contentsOf: root.appendingPathComponent("docs/stt-daemon.md"), encoding: .utf8)) ?? ""
        reporter.record("stt-daemon doc names the live LaunchAgent label",
                        doc.contains(DaemonClient.agentLabel))
        reporter.record("stt-daemon doc does not present the retired label as current",
                        !doc.contains("com.lifeos."))
    }

    private static func plistLabel(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = object as? [String: Any] else { return nil }
        return plist["Label"] as? String
    }

    private static func checkInstallerOrder(_ reporter: SelfTestReporter,
                                            root: URL,
                                            filename: String,
                                            legacyLabel: String,
                                            newLabel: String) {
        guard let script = try? String(
            contentsOf: root.appendingPathComponent(filename), encoding: .utf8),
              let oldDeclaration = script.range(of: "OLD_LABEL=\"\(legacyLabel)\""),
              let newDeclaration = script.range(of: "LABEL=\"\(newLabel)\""),
              let oldBootout = script.range(of: "launchctl bootout \"gui/$U/$OLD_LABEL\""),
              let bootstrap = script.range(of: "launchctl bootstrap \"gui/$U\" \"$PLIST_DST\"") else {
            reporter.record("\(filename) declares and migrates both LaunchAgent labels", false)
            return
        }
        reporter.record("\(filename) declares both old and new LaunchAgent labels",
                        oldDeclaration.lowerBound < newDeclaration.lowerBound)
        reporter.record("\(filename) boots out the old label before the new bootstrap",
                        oldBootout.lowerBound < bootstrap.lowerBound)
    }
}
