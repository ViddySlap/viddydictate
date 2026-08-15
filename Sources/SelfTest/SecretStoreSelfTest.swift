import Foundation
import Security

/// Characterizes the secret store's resolution policy and the off-state a user actually sees.
///
/// Deliberately touches NO real keychain. The deterministic tier runs under a scratch `HOME`, and a
/// gate that read the live login keychain would go green or red on whether this particular machine
/// happens to have a key stored — machine state, not policy. So the policy is asserted through the
/// pure injection seam, and the Keychain read/write path is exercised by hand (`--set-gemini-key`)
/// and by Option+G itself.
enum SecretStoreSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate secret store - selftest ===")
        let reporter = SelfTestReporter()

        checkResolutionOrder(reporter)
        checkExistenceOnlyResolution(reporter)
        checkBlankHandling(reporter)
        checkStorageSchema(reporter)
        checkLegacyServiceMigration(reporter)
        checkOffState(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "secret store"))
        return reporter.passed
    }

    // MARK: - Locked order: Keychain, then the environment override, then nothing

    private static func checkResolutionOrder(_ check: SelfTestReporter) {
        print("--- resolution order ---")

        check("keychain alone resolves from the keychain",
              SecretStore.resolve(keychain: "k-value", environment: nil)
                == SecretStore.Resolution(value: "k-value", source: .keychain))

        check("environment alone resolves from the environment",
              SecretStore.resolve(keychain: nil, environment: "e-value")
                == SecretStore.Resolution(value: "e-value", source: .environment))

        // The spec's locked order. An installed user's stored key must not be silently displaced by a
        // stale exported variable in whatever shell happened to launch the app.
        check("keychain WINS over the environment override",
              SecretStore.resolve(keychain: "k-value", environment: "e-value")
                == SecretStore.Resolution(value: "k-value", source: .keychain))

        check("neither source resolves to nil (the feature reports itself off)",
              SecretStore.resolve(keychain: nil, environment: nil) == nil)
    }

    // MARK: - Status resolution never asks Keychain for secret data

    private static func checkExistenceOnlyResolution(_ check: SelfTestReporter) {
        print("--- existence-only source resolution ---")

        check("an existing keychain item reports the keychain source",
              SecretStore.resolveSource(keychainExists: true, environment: nil) == .keychain)
        check("the keychain source WINS over the environment override",
              SecretStore.resolveSource(keychainExists: true, environment: "e-value") == .keychain)
        check("an absent keychain item falls through to the environment source",
              SecretStore.resolveSource(keychainExists: false, environment: "e-value") == .environment)
        check("neither existing source reports nil",
              SecretStore.resolveSource(keychainExists: false, environment: " \n ") == nil)

        let query = SecretStore.existenceQuery(.geminiAPIKey)
        check("the existence probe requests attributes",
              query[kSecReturnAttributes as String] as? Bool == true)
        check("the existence probe NEVER requests secret data",
              query[kSecReturnData as String] == nil)
        check("the existence probe is limited to one match",
              query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
    }

    // MARK: - Blank is absent, at every layer

    private static func checkBlankHandling(_ check: SelfTestReporter) {
        print("--- blank and whitespace entries ---")

        check("an empty keychain entry falls through to the environment",
              SecretStore.resolve(keychain: "", environment: "e-value")
                == SecretStore.Resolution(value: "e-value", source: .environment))

        // A key piped in through a shell arrives with a trailing newline; storing it verbatim and then
        // sending it as a credential is an opaque provider 400, not an obvious local mistake.
        check("a whitespace-only keychain entry falls through to the environment",
              SecretStore.resolve(keychain: "  \n\t ", environment: "e-value")
                == SecretStore.Resolution(value: "e-value", source: .environment))

        check("an empty environment override resolves to nil, not to an empty credential",
              SecretStore.resolve(keychain: nil, environment: "") == nil)

        check("a resolved value is trimmed",
              SecretStore.resolve(keychain: "\n k-value \n", environment: nil)?.value == "k-value")

        check("normalized maps blank to nil", SecretStore.normalized(" \n ") == nil)
        check("normalized preserves an interior space", SecretStore.normalized(" a b ") == "a b")
    }

    // MARK: - Storage schema (renaming these orphans a user's stored secret)

    private static func checkStorageSchema(_ check: SelfTestReporter) {
        print("--- storage schema ---")

        check("service attribute is the new bundle identifier",
              SecretStore.service == "com.viddydictate.app"
                && SecretStore.service == AppIdentity.bundleID)
        check("legacy service remains migration-only schema",
              SecretStore.legacyService == "com.viddyslap.viddydictate")
        check("gemini account name is stable", SecretStore.Secret.geminiAPIKey.rawValue == "gemini-api-key")
        check("every secret has a distinct account name",
              Set(SecretStore.Secret.allCases.map(\.rawValue)).count == SecretStore.Secret.allCases.count)

        for secret in SecretStore.Secret.allCases {
            check("\(secret.rawValue): environment override is namespaced",
                  secret.environmentVariable.hasPrefix("VIDDYDICTATE_"))
            check("\(secret.rawValue): setup hint names the environment override",
                  secret.setupHint.contains(secret.environmentVariable))
            check("\(secret.rawValue): has a human label", !secret.label.isEmpty)
        }
    }

    // MARK: - Legacy service copy is guarded, non-destructive, and retryable

    private static func checkLegacyServiceMigration(_ check: SelfTestReporter) {
        print("--- legacy Keychain service migration ---")
        checkLegacyCopyAndGuard(check)
        checkDestinationWins(check)
        checkFailureRetries(check)
        checkAbsentSource(check)
        checkMarkerIsVersionedPastThePoisonedKey(check)
    }

    private static func checkLegacyCopyAndGuard(_ check: SelfTestReporter) {
        let secret = SecretStore.Secret.geminiAPIKey
        let payload = Data("synthetic-key".utf8)
        withSyntheticDefaults { defaults in
            var statusServices: [String] = []
            var readServices: [String] = []
            var writeServices: [String] = []
            var writtenData: [Data] = []
            let complete = SecretStore.migrateLegacyItemsIfNeeded(
                defaults: defaults,
                itemStatus: { _, service in
                    statusServices.append(service)
                    return errSecItemNotFound
                },
                readItem: { _, service in
                    readServices.append(service)
                    return (errSecSuccess, payload)
                },
                writeItem: { _, service, data in
                    writeServices.append(service)
                    writtenData.append(data)
                    return errSecSuccess
                })
            let copiedExactly = statusServices == [SecretStore.service]
                && readServices == [SecretStore.legacyService]
                && writeServices == [SecretStore.service]
                && writtenData == [payload]
            check("missing destination copies the legacy Gemini item into the new service",
                  complete && copiedExactly && secret.rawValue == "gemini-api-key")
            check("successful Keychain copy records the persistent guard",
                  defaults.bool(forKey: SecretStore.legacyMigrationMarker))

            statusServices.removeAll()
            readServices.removeAll()
            writeServices.removeAll()
            let guarded = SecretStore.migrateLegacyItemsIfNeeded(
                defaults: defaults,
                itemStatus: { _, service in statusServices.append(service); return errSecAuthFailed },
                readItem: { _, service in readServices.append(service); return (errSecAuthFailed, nil) },
                writeItem: { _, service, _ in writeServices.append(service); return errSecAuthFailed })
            check("the persistent guard prevents repeated Keychain access",
                  guarded && statusServices.isEmpty && readServices.isEmpty && writeServices.isEmpty)
        }
    }

    private static func checkDestinationWins(_ check: SelfTestReporter) {
        withSyntheticDefaults { defaults in
            var readCount = 0
            var writeCount = 0
            let complete = SecretStore.migrateLegacyItemsIfNeeded(
                defaults: defaults,
                itemStatus: { _, service in
                    service == SecretStore.service ? errSecSuccess : errSecItemNotFound
                },
                readItem: { _, _ in readCount += 1; return (errSecItemNotFound, nil) },
                writeItem: { _, _, _ in writeCount += 1; return errSecSuccess })
            check("an existing destination item wins without reading or overwriting legacy data",
                  complete && readCount == 0 && writeCount == 0
                    && defaults.bool(forKey: SecretStore.legacyMigrationMarker))
        }
    }

    private static func checkFailureRetries(_ check: SelfTestReporter) {
        let payload = Data("synthetic-key".utf8)
        withSyntheticDefaults { defaults in
            var writeAttempts = 0
            let first = SecretStore.migrateLegacyItemsIfNeeded(
                defaults: defaults,
                itemStatus: { _, _ in errSecItemNotFound },
                readItem: { _, service in
                    (service == SecretStore.legacyService ? errSecSuccess : errSecItemNotFound, payload)
                },
                writeItem: { _, _, _ in
                    writeAttempts += 1
                    return errSecInteractionNotAllowed
                })
            check("a transient Keychain write failure leaves migration unmarked for retry",
                  !first && writeAttempts == 1
                    && !defaults.bool(forKey: SecretStore.legacyMigrationMarker))

            let second = SecretStore.migrateLegacyItemsIfNeeded(
                defaults: defaults,
                itemStatus: { _, _ in errSecItemNotFound },
                readItem: { _, _ in (errSecSuccess, payload) },
                writeItem: { _, _, _ in writeAttempts += 1; return errSecSuccess })
            check("the next launch retries and completes the failed Keychain copy",
                  second && writeAttempts == 2
                    && defaults.bool(forKey: SecretStore.legacyMigrationMarker))
        }
    }

    /// A blind lookup must never retire the migration.
    ///
    /// This assertion used to read the other way - an absent legacy item "completed" the migration and
    /// latched the marker. It was wrong for the one input that matters: a process that cannot reach the
    /// Keychain at all reports `errSecItemNotFound` too, so a single blind launch permanently retired a
    /// migration that had not run, leaving a real stored key orphaned under the old service. Measured on
    /// 2026-08-15: the marker was latched in the live `com.viddydictate.app` domain while the legacy
    /// `gemini-api-key` item still sat unmigrated in the login Keychain.
    private static func checkAbsentSource(_ check: SelfTestReporter) {
        withSyntheticDefaults { defaults in
            var writeCount = 0
            let complete = SecretStore.migrateLegacyItemsIfNeeded(
                defaults: defaults,
                itemStatus: { _, _ in errSecItemNotFound },
                readItem: { _, _ in (errSecItemNotFound, nil) },
                writeItem: { _, _, _ in writeCount += 1; return errSecSuccess })
            check("an absent-or-unreadable legacy item creates no empty destination and does NOT latch",
                  !complete && writeCount == 0
                    && !defaults.bool(forKey: SecretStore.legacyMigrationMarker))

            // ...and the very next launch, once the Keychain answers, still migrates.
            let payload = Data("synthetic-key".utf8)
            var wrote: [Data] = []
            let recovered = SecretStore.migrateLegacyItemsIfNeeded(
                defaults: defaults,
                itemStatus: { _, _ in errSecItemNotFound },
                readItem: { _, service in
                    (service == SecretStore.legacyService ? errSecSuccess : errSecItemNotFound, payload)
                },
                writeItem: { _, _, data in wrote.append(data); return errSecSuccess })
            check("a later launch that CAN see the legacy item still migrates it",
                  recovered && wrote == [payload]
                    && defaults.bool(forKey: SecretStore.legacyMigrationMarker))
        }
    }

    /// The marker key itself is part of the fix: machines that latched the unversioned key before
    /// 2026-08-15 hold an unmigrated item, and only a different key makes them retry.
    private static func checkMarkerIsVersionedPastThePoisonedKey(_ check: SelfTestReporter) {
        check("the migration marker is not the poisoned unversioned key",
              SecretStore.legacyMigrationMarker != SecretStore.supersededLegacyMigrationMarker
                && SecretStore.supersededLegacyMigrationMarker
                    == "didMigrateKeychainFromComViddyslapViddyDictate")
        withSyntheticDefaults { defaults in
            defaults.set(true, forKey: SecretStore.supersededLegacyMigrationMarker)
            var readServices: [String] = []
            _ = SecretStore.migrateLegacyItemsIfNeeded(
                defaults: defaults,
                itemStatus: { _, _ in errSecItemNotFound },
                readItem: { _, service in readServices.append(service); return (errSecItemNotFound, nil) },
                writeItem: { _, _, _ in errSecSuccess })
            check("a machine latched by the old key still re-attempts the migration",
                  readServices == [SecretStore.legacyService])
        }
    }

    private static func withSyntheticDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "test.viddydictate.secret-migration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    // MARK: - The off state a user actually reads

    private static func checkOffState(_ check: SelfTestReporter) {
        print("--- Option+G off state ---")

        guard case .unavailable(let message) = SearchClient.geminiOffResult() else {
            check("no key yields an unavailable result", false)
            return
        }
        check("no key yields an unavailable result", true)
        check("off message names the feature", message.contains("Gemini API key"))
        // The whole point of the message: a user who sees it can fix it without reading the source.
        check("off message names the command that fixes it", message.contains("set-gemini-key.sh"))
        check("off message names the environment override",
              message.contains(SecretStore.Secret.geminiAPIKey.environmentVariable))
        // The retired vault scrape must not come back through the copy either: nothing about this key
        // is reachable from a vault path any more.
        check("off message does not mention a vault path",
              !message.lowercased().contains("secrets.md") && !message.contains("Documents"))
        check("off message is plain ASCII", message.allSatisfy(\.isASCII))

        // The failure a user hits when they run the setup script over ssh or from a background job.
        // It has to say WHERE to run it, not just quote a negative number.
        let locked = SecretStore.explain(errSecInteractionNotAllowed)
        check("a locked-keychain failure names the session, not just a number",
              locked.contains("Terminal") && locked.contains("ssh"))
        check("an unrecognized status still carries its number",
              SecretStore.explain(-99999).contains("-99999"))
    }
}
