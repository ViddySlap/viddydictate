import Foundation

/// Deterministic regression for the locked foreign-app branch. The fake target reproduces the measured
/// failure shape: AX reports success but drops the text. No real Accessibility element, pasteboard, app,
/// or event tap is touched.
enum LockedDeliverySelfTest {
    static func run() -> Bool {
        print("--- locked-delivery captured-target recovery selftest ---")
        let reporter = SelfTestReporter()
        let check = reporter
        let text = "locked delivery must survive"

        // The pre-discovery branch trusted the AX Boolean. A lying success therefore claimed `.foreign`
        // while leaving no text in the fake field, no clipboard recovery, and no warning.
        let liarSink = LockedDeliverySpy()
        let liar = LockedDeliveryFakeTarget(axResult: true, sink: liarSink)
        let liarReceipt = LockedDeliveryLegacyHarness.deliver(text, target: liar, sink: liarSink)
        check("legacy lying AX success reports a foreign landing",
              liarReceipt == .foreign && liar.axAttempts == 1)
        check("legacy lying AX success silently drops every durable copy",
              liar.fieldText == nil && liarSink.clipboard == nil && liarSink.toast == nil)

        // The legacy conjunction had two independent clipboard-net triggers. Pin both so a future cleanup
        // cannot mistake `target == nil` for the only fallback case.
        let falseSink = LockedDeliverySpy()
        let falseTarget = LockedDeliveryFakeTarget(axResult: false, sink: falseSink)
        let falseReceipt = LockedDeliveryLegacyHarness.deliver(text, target: falseTarget, sink: falseSink)
        check("legacy insertViaAX false reaches clipboard receipt + toast",
              falseReceipt == .clipboard
                && falseTarget.axAttempts == 1
                && falseSink.clipboard == text
                && falseSink.toast != nil)

        let nilSink = LockedDeliverySpy()
        let nilReceipt = LockedDeliveryLegacyHarness.deliver(
            text, target: Optional<LockedDeliveryFakeTarget>.none, sink: nilSink)
        check("legacy nil target independently reaches clipboard receipt + toast",
              nilReceipt == .clipboard && nilSink.clipboard == text && nilSink.toast != nil)

        // The production replacement is completion-based. The fake captured-target paste reports a failed
        // event dispatch after preserving the text on its fake clipboard, mirroring TargetResolver's honest
        // `.clipboardOnly` contract.
        let capturedSink = LockedDeliverySpy()
        let captured = LockedDeliveryFakeTarget(axResult: true, sink: capturedSink)
        var capturedReceipt: LockedDeliveryTestReceipt?
        captured.pasteIntoCapturedTarget(text) { outcome in
            let resolution = DictationController.lockedDeliveryResolution(
                targetAvailable: true, outcome: outcome)
            capturedReceipt = LockedDeliveryLegacyHarness.apply(
                resolution, text: text, sink: capturedSink)
        }
        check("captured-target paste bypasses the lying AX write",
              captured.axAttempts == 0 && captured.capturedPasteAttempts == 1)
        check("captured-target failure preserves text once on the clipboard",
              captured.fieldText == nil
                && capturedSink.clipboard == text
                && capturedSink.clipboardWrites == 1)
        check("captured-target failure reports an honest toast + clipboard receipt",
              capturedReceipt == .clipboard
                && capturedSink.toast?.contains("paste shortcut could not be sent") == true)

        // Pin the actual production call site as well as the injected behavior above: locked delivery must
        // call the captured-target primitive directly, never the bare current-focus paste or legacy AX helper.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let controllerSource = NotesProbe.sourceDictationController
        let resolverSource = (try? String(
            contentsOf: root.appendingPathComponent("Sources/App/TargetResolver.swift"),
            encoding: .utf8)) ?? ""
        let lockedBranch = NotesProbe.sourceSlice(controllerSource,
                                                  from: "private func deliverLocked(",
                                                  to: "private func deliverLockedNoTarget(")
        check("production locked branch calls pasteIntoCapturedTarget",
              lockedBranch.contains("TargetResolver.pasteIntoCapturedTarget"))
        check("production locked branch has no AX or bare-focus delivery call",
              !lockedBranch.contains("TargetResolver.insertViaAX")
                && !lockedBranch.contains("TargetResolver.pasteIntoFocus"))
        check("production locked branch completes foreign and clipboard receipts",
              lockedBranch.contains("finish(.foreign") && lockedBranch.contains("finish(.clipboard"))
        check("legacy insertViaAX remains bannered as unused pre-discovery code",
              resolverSource.contains("PRE-DISCOVERY / UNUSED")
                && resolverSource.contains("static func insertViaAX"))

        print(reporter.summaryLine(prefix: "[locked-delivery-selftest]"))
        return reporter.passed
    }

}

private enum LockedDeliveryTestReceipt: Equatable {
    case foreign
    case clipboard
}

private final class LockedDeliverySpy {
    private(set) var clipboard: String?
    private(set) var clipboardWrites = 0
    private(set) var toast: String?

    func copyToClipboard(_ text: String) {
        clipboard = text
        clipboardWrites += 1
    }

    func showToast(_ text: String) {
        toast = text
    }
}

private final class LockedDeliveryFakeTarget {
    let axResult: Bool
    let sink: LockedDeliverySpy
    private(set) var axAttempts = 0
    private(set) var capturedPasteAttempts = 0
    private(set) var fieldText: String?

    init(axResult: Bool, sink: LockedDeliverySpy) {
        self.axResult = axResult
        self.sink = sink
    }

    /// Deliberately never mutates `fieldText`: `.success` is the lie under regression.
    func insertViaAX(_ text: String) -> Bool {
        axAttempts += 1
        return axResult
    }

    func pasteIntoCapturedTarget(
        _ text: String,
        completion: (TargetResolver.CapturedTargetLandingOutcome) -> Void
    ) {
        capturedPasteAttempts += 1
        sink.copyToClipboard(text)
        completion(.clipboardOnly(.eventDispatchFailed))
    }
}

private enum LockedDeliveryLegacyHarness {
    static func deliver(
        _ text: String,
        target: LockedDeliveryFakeTarget?,
        sink: LockedDeliverySpy
    ) -> LockedDeliveryTestReceipt {
        if let target = target, target.insertViaAX(text) {
            return .foreign
        }
        return apply(
            DictationController.lockedDeliveryResolution(targetAvailable: false, outcome: nil),
            text: text,
            sink: sink)
    }

    static func apply(
        _ resolution: DictationController.LockedDeliveryResolution,
        text: String,
        sink: LockedDeliverySpy
    ) -> LockedDeliveryTestReceipt {
        if resolution.shouldCopyToClipboard { sink.copyToClipboard(text) }
        if let toast = resolution.toast { sink.showToast(toast) }
        switch resolution.receipt {
        case .foreign: return .foreign
        case .clipboard: return .clipboard
        }
    }
}
