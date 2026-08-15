import Foundation
import Security

/// The app's only secret store: a login-keychain generic password per secret, with a testing-only
/// environment override underneath it.
///
/// Replaces the previous machine-specific Markdown-file scrape, which required the app to hold
/// Documents access purely to read a key. The resolution order
/// is locked by the Public V1 spec (W2): **Keychain, then the environment override, then nothing** —
/// and "nothing" is a first-class outcome, not an error: the feature reports itself off with a
/// specific, actionable reason and every other mode keeps working.
///
/// The Keychain item is written by the app itself (`--set-gemini-key`, value on stdin) rather than by
/// `security add-generic-password`, because the creating process lands on the item's access list: an
/// app-written item is read back without an authorization prompt, a terminal-written one is not.
///
/// Nothing here ever logs, prints, or passes a secret value through argv.
enum SecretStore {

    /// Every secret ViddyDictate holds. The raw value is the Keychain account name, so renaming a
    /// case orphans the stored item — treat these strings as storage schema, not as labels.
    enum Secret: String, CaseIterable {
        case geminiAPIKey = "gemini-api-key"

        /// Human-facing name for status and preflight copy.
        var label: String {
            switch self {
            case .geminiAPIKey: return "Gemini API key"
            }
        }

        /// Testing-only override, read only when the Keychain has nothing. Namespaced so it cannot
        /// collide with the vendor variables an unrelated tool may already export.
        var environmentVariable: String {
            switch self {
            case .geminiAPIKey: return "VIDDYDICTATE_GEMINI_API_KEY"
            }
        }

        /// What to tell the user when the secret is absent. This is the whole user-facing recovery
        /// path for an off feature, so it names the command rather than describing it.
        var setupHint: String {
            switch self {
            case .geminiAPIKey:
                return "run ./scripts/set-gemini-key.sh (or set \(environmentVariable) for a test run)"
            }
        }
    }

    /// Keychain service attribute. Matches the bundle identifier so the items are attributable in
    /// Keychain Access and cannot collide with another app's generic passwords.
    static let service = AppIdentity.bundleID
    static let legacyService = AppIdentity.legacyBundleID
    /// Versioned deliberately. The unversioned `...ViddyDictate` key latched "migration done" on any
    /// launch whose legacy lookup reported `errSecItemNotFound`, which a Keychain-denied process is
    /// indistinguishable from. Machines that latched it that way still hold an unmigrated item, so the
    /// key had to change for them to retry at all. Never reuse the unversioned spelling.
    static let legacyMigrationMarker = "didMigrateKeychainFromComViddyslapViddyDictate.v2"
    /// The poisoned original, kept only so a test can prove the current marker is not it.
    static let supersededLegacyMigrationMarker = "didMigrateKeychainFromComViddyslapViddyDictate"

    enum LegacyMigrationOutcome: Equatable {
        case destinationPresent
        case sourceAbsent
        case copied
        case retry(OSStatus)
    }

    typealias ItemStatus = (Secret, String) -> OSStatus
    typealias ItemReader = (Secret, String) -> (OSStatus, Data?)
    typealias ItemWriter = (Secret, String, Data) -> OSStatus

    enum Source: String {
        case keychain
        case environment
    }

    struct Resolution: Equatable {
        let value: String
        let source: Source
    }

    // MARK: - Resolution policy (pure)

    /// The locked order, expressed as a pure function so the deterministic rail can assert it without
    /// a login keychain — the verification tiers run under a scratch `HOME`, and a gate that reads the
    /// real keychain would pass or fail on machine state rather than on this policy.
    static func resolve(keychain: String?, environment: String?) -> Resolution? {
        if let value = normalized(keychain) { return Resolution(value: value, source: .keychain) }
        if let value = normalized(environment) { return Resolution(value: value, source: .environment) }
        return nil
    }

    /// The same source order for callers that only need to know whether a secret is available. The
    /// Keychain side is deliberately a Boolean so deterministic tests can cover the policy without
    /// reading a login keychain or handling a secret value.
    static func resolveSource(keychainExists: Bool, environment: String?) -> Source? {
        if keychainExists { return .keychain }
        if normalized(environment) != nil { return .environment }
        return nil
    }

    /// A present-but-blank entry means absent. A stored key that is all whitespace (a stray newline
    /// from a shell pipeline, an emptied env var) must fall through to the next source rather than
    /// arriving at the provider as an empty credential and returning an opaque 400.
    static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - Resolution (live)

    static func resolve(_ secret: Secret,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Resolution? {
        resolve(keychain: read(secret), environment: environment[secret.environmentVariable])
    }

    /// Source-only resolution for status and preflight surfaces. Unlike `resolve`, this never asks
    /// Keychain for the secret data, so opening Settings cannot trigger a value-access dialog.
    static func resolveSource(_ secret: Secret,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> Source? {
        resolveSource(keychainExists: keychainContains(secret),
                      environment: environment[secret.environmentVariable])
    }

    /// The one-liner most callers want: the value, or nil meaning "this feature is off".
    static func value(_ secret: Secret) -> String? { resolve(secret)?.value }

    // MARK: - Keychain

    private static func baseQuery(_ secret: Secret, service targetService: String = service)
        -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: targetService,
            kSecAttrAccount as String: secret.rawValue,
        ]
    }

    /// Attributes are enough to prove that the item exists. Keep this separate from `read`: adding
    /// `kSecReturnData` here would turn a harmless Settings status refresh into secret-value access.
    static func existenceQuery(_ secret: Secret, service targetService: String = service)
        -> [String: Any] {
        var query = baseQuery(secret, service: targetService)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private static func itemStatus(_ secret: Secret, service targetService: String) -> OSStatus {
        var item: CFTypeRef?
        return SecItemCopyMatching(
            existenceQuery(secret, service: targetService) as CFDictionary, &item)
    }

    private static func keychainContains(_ secret: Secret) -> Bool {
        let status = itemStatus(secret, service: service)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.write("secrets: keychain existence probe failed for \(secret.rawValue) "
                    + "(OSStatus \(status))")
            }
            return false
        }
        return true
    }

    /// Returns nil for "not stored" AND for any read failure. A locked keychain or a denied
    /// authorization is indistinguishable from absence to the caller by design: both mean the feature
    /// cannot run right now, and both should degrade to the off state rather than to a crash.
    static func read(_ secret: Secret) -> String? {
        let (status, data) = itemData(secret, service: service)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.write("secrets: keychain read failed for \(secret.rawValue) (OSStatus \(status))")
            }
            return nil
        }
        guard let data, let text = String(data: data, encoding: .utf8) else {
            Log.write("secrets: keychain item \(secret.rawValue) is not UTF-8 text")
            return nil
        }
        return text
    }

    private static func itemData(_ secret: Secret, service targetService: String)
        -> (OSStatus, Data?) {
        var query = baseQuery(secret, service: targetService)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    /// Upsert. Returns `errSecSuccess` or the failing status; never logs the value.
    @discardableResult
    static func write(_ secret: Secret, value: String) -> OSStatus {
        writeData(secret, service: service, data: Data(value.utf8))
    }

    private static func writeData(_ secret: Secret, service targetService: String,
                                  data: Data) -> OSStatus {
        let update = SecItemUpdate(baseQuery(secret, service: targetService) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update != errSecItemNotFound { return update }   // success, or a real failure worth surfacing

        var insert = baseQuery(secret, service: targetService)
        insert[kSecValueData as String] = data
        insert[kSecAttrDescription as String] = "ViddyDictate \(secret.label)"
        return SecItemAdd(insert as CFDictionary, nil)
    }

    /// Copy legacy-service items forward without deleting the originals. Destination items always
    /// win. Transient Keychain errors leave the marker unset so the next launch retries safely.
    ///
    /// The marker records "the destination is populated", NOT "we tried once". That distinction is
    /// load-bearing: `errSecItemNotFound` on the legacy lookup means either "the user never had this
    /// secret" or "this process could not see the Keychain at all", and the two are indistinguishable
    /// to the caller. Latching on that answer let one blind launch - a sandboxed verification run,
    /// say - permanently retire a migration that had not happened, orphaning a real stored key under
    /// the old service forever. So an absent source now leaves the marker unset and the probe repeats.
    /// The repeat costs two `SecItemCopyMatching` calls per launch and stops as soon as the
    /// destination holds every secret, which is exactly when there is something to protect.
    @discardableResult
    static func migrateLegacyItemsIfNeeded() -> Bool {
        migrateLegacyItemsIfNeeded(
            defaults: .standard,
            itemStatus: { itemStatus($0, service: $1) },
            readItem: { itemData($0, service: $1) },
            writeItem: { writeData($0, service: $1, data: $2) })
    }

    @discardableResult
    static func migrateLegacyItemsIfNeeded(defaults: UserDefaults,
                                           itemStatus: ItemStatus,
                                           readItem: ItemReader,
                                           writeItem: ItemWriter) -> Bool {
        if defaults.bool(forKey: legacyMigrationMarker) { return true }

        var complete = true
        for secret in Secret.allCases {
            let outcome = migrateLegacyItem(
                secret, itemStatus: itemStatus, readItem: readItem, writeItem: writeItem)
            switch outcome {
            case .destinationPresent, .copied:
                continue
            case .sourceAbsent:
                // Not an error, and not a completion either: see the note on the wrapper above.
                complete = false
            case .retry(let status):
                complete = false
                Log.write("secrets: legacy Keychain migration will retry for \(secret.rawValue) "
                    + "(OSStatus \(status))")
            }
        }
        if complete { defaults.set(true, forKey: legacyMigrationMarker) }
        return complete
    }

    static func migrateLegacyItem(_ secret: Secret,
                                  itemStatus: ItemStatus,
                                  readItem: ItemReader,
                                  writeItem: ItemWriter) -> LegacyMigrationOutcome {
        let destinationStatus = itemStatus(secret, service)
        if destinationStatus == errSecSuccess { return .destinationPresent }
        guard destinationStatus == errSecItemNotFound else { return .retry(destinationStatus) }

        let (sourceStatus, data) = readItem(secret, legacyService)
        if sourceStatus == errSecItemNotFound { return .sourceAbsent }
        guard sourceStatus == errSecSuccess, let data else {
            return .retry(sourceStatus == errSecSuccess ? errSecDecode : sourceStatus)
        }

        let writeStatus = writeItem(secret, service, data)
        return writeStatus == errSecSuccess ? .copied : .retry(writeStatus)
    }

    /// Deleting an absent item is success — "make sure this is gone" is the caller's intent.
    @discardableResult
    static func delete(_ secret: Secret) -> OSStatus {
        let status = SecItemDelete(baseQuery(secret) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    /// Plain language for the statuses a user can actually hit, because a bare OSStatus number is not
    /// a fix. `errSecInteractionNotAllowed` is the one that bites in practice: it is what a process
    /// outside the logged-in GUI session gets (an ssh shell, a launchd job, an agent's shell), and it
    /// reads as a mysterious failure rather than as "you are in the wrong session".
    static func explain(_ status: OSStatus) -> String {
        switch status {
        case errSecInteractionNotAllowed:
            return "the login keychain is locked to this process - run this from Terminal while "
                 + "logged in at the Mac, not over ssh or from a background job (OSStatus \(status))"
        case errSecAuthFailed:
            return "keychain authorization was refused (OSStatus \(status))"
        case errSecUserCanceled:
            return "the keychain prompt was dismissed (OSStatus \(status))"
        default:
            return "OSStatus \(status)"
        }
    }

    // MARK: - Shipped-app CLI (the only way to populate the store until Settings owns it)

    /// Reads the value from **stdin**, never argv: an argument is visible in `ps` to every process on
    /// the machine, which is the same argv/stdin discipline the web-search transport already follows.
    static func runSetFromStdin(_ secret: Secret) -> Int32 {
        let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
        guard let value = normalized(raw) else {
            FileHandle.standardError.write(Data(
                "[viddydictate] no \(secret.label) on stdin; nothing written\n".utf8))
            return 2
        }
        let status = write(secret, value: value)
        guard status == errSecSuccess else {
            FileHandle.standardError.write(Data(
                "[viddydictate] could not store the \(secret.label): \(explain(status))\n".utf8))
            return 1
        }
        print("[viddydictate] stored the \(secret.label) in the login keychain (\(service)/\(secret.rawValue))")
        return 0
    }

    /// Reports whether the secret resolves and from where, WITHOUT printing it. The only way to verify
    /// a stored secret without a human reading the value out of Keychain Access — and the shape the
    /// first-run preflight will read.
    static func runStatus(_ secret: Secret) -> Int32 {
        guard let resolution = resolve(secret) else {
            print("[viddydictate] \(secret.label): not set - \(secret.setupHint)")
            return 1
        }
        print("[viddydictate] \(secret.label): set (source \(resolution.source.rawValue), "
              + "\(resolution.value.count) characters)")
        return 0
    }

    static func runClear(_ secret: Secret) -> Int32 {
        let status = delete(secret)
        guard status == errSecSuccess else {
            FileHandle.standardError.write(Data(
                "[viddydictate] could not remove the \(secret.label): \(explain(status))\n".utf8))
            return 1
        }
        print("[viddydictate] removed the \(secret.label) from the login keychain")
        return 0
    }
}
