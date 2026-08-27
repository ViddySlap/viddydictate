import Foundation

/// Offline proof for the L7 lifecycle. It drives the same state and persistence seams the future picker
/// uses, without installing a venv, starting LM Studio, launching the app, or touching live Application
/// Support. A row is intentionally made usable before its sibling so the non-wall behavior is explicit.
enum BootstrapStateSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate bootstrap lifecycle - selftest ===")
        let reporter = SelfTestReporter()
        let check = reporter.check
        let core = BootstrapInstallPlan.mandatoryCore
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-bootstrap-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent(BootstrapStateStore.fileName)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = BootstrapStateStore(url: url, descriptors: core)
            checkFresh(store.snapshot(), check: reporter, core: core)

            store.beginDownload()
            check("starting setup enters the downloading state", store.snapshot().lifecycle == .downloading)

            store.markInstalling(componentID: core[0].id)
            check("only the active component is marked installing",
                  store.snapshot().component(core[0].id)?.phase == .installing
                    && store.snapshot().component(core[1].id)?.phase == .pending)

            store.apply(installed(core[0]))
            let oneLive = store.snapshot()
            check("a completed component becomes usable before its sibling completes",
                  oneLive.isComponentUsable(core[0].id) && !oneLive.isComponentUsable(core[1].id))
            check("a partially installed core remains reduced and re-presentable",
                  oneLive.isReduced && oneLive.shouldPresentSetupOnLaunch
                    && oneLive.persistentBanner == nil)

            store.cancel()
            let cancelled = store.snapshot()
            check("Set up later enters the one degraded lifecycle", cancelled.lifecycle == .degraded)
            check("the degraded state carries the exact persistent recovery banner",
                  cancelled.persistentBanner == BootstrapSnapshot.degradedBanner)
            check("cancellation does not erase the component that already went live",
                  cancelled.isComponentUsable(core[0].id))

            store.beginDownload()
            store.markInstalling(componentID: core[1].id)
            let detail = "ERROR: Could not resolve huggingface.co (connection reset by peer)"
            store.apply(failed(core[1], message: detail, attempts: 3))
            let failedState = store.snapshot()
            check("a three-attempt row failure enters the same degraded state as cancellation",
                  failedState.lifecycle == .degraded)
            check("the failed row retains its real error and attempt count",
                  failedState.component(core[1].id)?.failureMessage == detail
                    && failedState.component(core[1].id)?.attempts == 3)
            check("a failed row does not make a completed sibling unavailable",
                  failedState.isComponentUsable(core[0].id))
            check("the degraded detail names the row and preserves the real error",
                  failedState.degradedDetail == "\(core[1].title): \(detail)")
            check("the failed state still requires setup on the next launch",
                  failedState.shouldPresentSetupOnLaunch)

            store.beginDownload()
            check("retry resets only the failed row to pending",
                  store.snapshot().component(core[0].id)?.phase == .installed
                    && store.snapshot().component(core[1].id)?.phase == .pending
                    && store.snapshot().lifecycle == .downloading)
            store.markInstalling(componentID: core[1].id)
            store.apply(installed(core[1]))
            let complete = store.snapshot()
            check("the mandatory core completes when both independent rows land",
                  complete.lifecycle == .complete && complete.mandatoryCoreComplete)
            check("a complete core has no degraded banner and does not reappear on launch",
                  complete.persistentBanner == nil && !complete.shouldPresentSetupOnLaunch)

            let reopened = BootstrapStateStore(url: url, descriptors: core)
            check("the component lifecycle round-trips through atomic app-local state",
                  reopened.snapshot() == complete)

            let malformedURL = root.appendingPathComponent("malformed.json")
            let malformed = Data("not json".utf8)
            try malformed.write(to: malformedURL)
            _ = BootstrapStateStore(url: malformedURL, descriptors: core)
            check("a malformed state file is not overwritten during recovery",
                  try Data(contentsOf: malformedURL) == malformed)
        } catch {
            reporter.record("bootstrap lifecycle fixture setup", false, String(describing: error))
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "bootstrap lifecycle"))
        print(reporter.passed ? "\nBOOTSTRAP LIFECYCLE GREEN" : "\nBOOTSTRAP LIFECYCLE FAILED")
        return reporter.passed
    }

    private static func checkFresh(_ state: BootstrapSnapshot,
                                   check: SelfTestReporter,
                                   core: [InstallerComponentDescriptor]) {
        check.record("a fresh install starts with every mandatory row pending",
                     state.lifecycle == .idle
                        && state.components.map(\.id) == core.map(\.id)
                        && state.components.allSatisfy { $0.phase == .pending })
        check.record("a fresh install is reduced and must show setup again on launch",
                     state.isReduced && state.shouldPresentSetupOnLaunch)
        check.record("a fresh install has no failure detail or degraded banner",
                     state.degradedDetail == nil && state.persistentBanner == nil)
    }

    private static func installed(_ descriptor: InstallerComponentDescriptor)
        -> InstallerComponentResult {
        InstallerComponentResult(componentID: descriptor.id, title: descriptor.title, state: .installed)
    }

    private static func failed(_ descriptor: InstallerComponentDescriptor,
                               message: String,
                               attempts: Int) -> InstallerComponentResult {
        InstallerComponentResult(
            componentID: descriptor.id,
            title: descriptor.title,
            state: .failed(InstallerFailure(category: .transport, message: message), attempts: attempts))
    }
}
