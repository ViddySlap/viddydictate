import Cocoa

/// Pure characterization for the shared HUD font and picker layout formulas.
enum HUDPolishSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate HUD polish - selftest ===")
        let reporter = SelfTestReporter()

        reporter.record(
            "phosphor font resolves without a system-font fallback",
            NSFont(name: Phosphor.font, size: 14) != nil
        )
        reporter.record(
            "cleanup keycap glyph follows rebound label",
            KeySpec.regular(keyCode: 18, label: "1").keycapGlyph == "1"
        )
        reporter.record(
            "cleanup keycap glyph strips dual legend",
            KeySpec.regular(keyCode: 44, label: "?/").keycapGlyph == "?"
        )

        var thinking = HUDThinkingActivity()
        let firstTake = UUID()
        let secondTake = UUID()
        thinking.setRecovery(takeID: firstTake, pending: true)
        thinking.setRecovery(takeID: secondTake, pending: true)
        thinking.setRecovery(takeID: firstTake, pending: false)
        reporter.record(
            "concurrent recoveries share one active thinking request until the final take clears",
            thinking.isActive && thinking.recoveryTakeIDs == [secondTake]
        )
        thinking.setRecovery(takeID: secondTake, pending: false)
        reporter.record("the final recovered take clears the thinking request", !thinking.isActive)

        let contentH: CGFloat = 137
        checkABPickerLayout(contentH: contentH, reporter: reporter)
        checkLevelPickerLayout(contentH: contentH, reporter: reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "HUD polish"))
        return reporter.passed
    }

    private static func checkABPickerLayout(contentH: CGFloat, reporter: SelfTestReporter) {
        let width: CGFloat = 760
        let padX: CGFloat = 22
        let headerH: CGFloat = 22
        let footerH: CGFloat = 18
        let padTop: CGFloat = 16
        let padMid: CGFloat = 12
        let padBottom: CGFloat = 14
        let layout = Phosphor.headerContentFooterLayout(
            width: width,
            contentH: contentH,
            padX: padX,
            headerH: headerH,
            footerH: footerH,
            padTop: padTop,
            padMid: padMid,
            padBottom: padBottom
        )
        let incumbentHeight = padTop + headerH + padMid + contentH + padMid + footerH + padBottom

        reporter.record("A/B picker total height matches incumbent formula", layout.totalHeight == incumbentHeight)
        reporter.record(
            "A/B picker header frame matches incumbent formula",
            layout.headerFrame == NSRect(
                x: padX,
                y: incumbentHeight - padTop - headerH,
                width: width - padX * 2,
                height: headerH
            )
        )
        reporter.record(
            "A/B picker content origin matches incumbent formula",
            layout.contentY == padBottom + footerH + padMid
        )
        reporter.record(
            "A/B picker footer frame matches incumbent formula",
            layout.footerFrame == NSRect(
                x: padX,
                y: padBottom,
                width: width - padX * 2,
                height: footerH
            )
        )
    }

    private static func checkLevelPickerLayout(contentH: CGFloat, reporter: SelfTestReporter) {
        let width: CGFloat = 540
        let padX: CGFloat = 22
        let headerH: CGFloat = 22
        let footerH: CGFloat = 18
        let padTop: CGFloat = 18
        let padMid: CGFloat = 16
        let padBottom: CGFloat = 14
        let layout = Phosphor.headerContentFooterLayout(
            width: width,
            contentH: contentH,
            padX: padX,
            headerH: headerH,
            footerH: footerH,
            padTop: padTop,
            padMid: padMid,
            padBottom: padBottom
        )
        let incumbentHeight = padTop + headerH + padMid + contentH + padMid + footerH + padBottom

        reporter.record("level picker total height matches incumbent formula", layout.totalHeight == incumbentHeight)
        reporter.record(
            "level picker header frame matches incumbent formula",
            layout.headerFrame == NSRect(
                x: padX,
                y: incumbentHeight - padTop - headerH,
                width: width - padX * 2,
                height: headerH
            )
        )
        reporter.record(
            "level picker content origin matches incumbent formula",
            layout.contentY == padBottom + footerH + padMid
        )
        reporter.record(
            "level picker footer frame matches incumbent formula",
            layout.footerFrame == NSRect(
                x: padX,
                y: padBottom,
                width: width - padX * 2,
                height: footerH
            )
        )
    }
}
