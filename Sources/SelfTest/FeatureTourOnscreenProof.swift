import Cocoa

/// `--feature-tour-onscreen-proof <outdir> [seconds]`: the Feature Tour as a REAL on-screen window, for a person
/// or a Mac worker to photograph. Opt-in, GUI tier, and deliberately NOT in scripts/verify.sh: it puts a window on
/// the screen and waits, which an unattended run must not do.
///
/// The offscreen render (`--feature-tour-render`) photographs pages it builds without the window; this is the
/// window itself, built by the controller's own `show(page:)`, so the backdrop, the pinned appearance and the
/// footer are the ones a user sees. It runs only in the TEST app process: the shipped app rejects the flag, and
/// would otherwise fight the running app for the keyboard event tap. Every live fact is the render gate's stub
/// (`FeatureTourRenderCases.controller()`), so nothing is measured, started or opened, and no tap is installed.
///
/// For each of the 11 pages it prints one line with the window number, then holds the page for `seconds`
/// (default 1), so a second shell can run the printed `screencapture -o -l <windowNumber> <file>`. It also tries
/// an in-process capture of that window with `CGWindowListCreateImage` and says whether it worked: that call can
/// need Screen Recording permission, and newer SDKs mark it unavailable, so it is looked up at run time and its
/// failure is reported, not failed. Exit 0 when every page was shown on screen in the tour window.
enum FeatureTourOnscreenProof {
    static func run(outDir: String, hold: TimeInterval) -> Bool {
        // Line-buffered, so a worker tailing this output sees each window number while the page is still up.
        setvbuf(stdout, nil, _IOLBF, 0)
        do { try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch {
            print("[feature-tour-onscreen-proof] FAIL: cannot create \(outDir): \(error)")
            return false
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let tour = FeatureTourRenderCases.controller()
        var shown = 0
        var inProcess = 0
        for index in tour.pages.indices {
            tour.show(page: index)
            pump(0.3)
            let name = String(format: "tour-onscreen-page-%02d-", index + 1) + tour.pages[index].id
            guard let window = app.windows.first(where: { $0.title == FeatureTour.windowTitle && $0.isVisible }),
                  window.windowNumber > 0, tour.index == index else {
                print("[feature-tour-onscreen-proof] FAIL page \(index + 1): the tour window is not on screen "
                    + "at this page")
                continue
            }
            shown += 1
            window.displayIfNeeded()
            print("[feature-tour-onscreen-proof] page \(index + 1) of \(tour.pages.count) "
                + "\(tour.pages[index].id) windowNumber=\(window.windowNumber) "
                + "appearance=\(window.effectiveAppearance.name.rawValue) "
                + "capture: screencapture -o -l \(window.windowNumber) \(outDir)/\(name)-screencapture.png")
            let result = captureInProcess(window, to: outDir + "/\(name).png")
            if result.hasPrefix("worked") { inProcess += 1 }
            print("[feature-tour-onscreen-proof]   in-process capture (CGWindowListCreateImage): \(result)")
            pump(hold)
        }
        app.windows.first { $0.title == FeatureTour.windowTitle }?.close()
        pump(0.1)
        let ok = shown == tour.pages.count
        print("[feature-tour-onscreen-proof] \(ok ? "PASS" : "FAIL"): \(shown) of \(tour.pages.count) pages shown "
            + "on screen; in-process capture worked for \(inProcess) of \(tour.pages.count)")
        return ok
    }

    /// Runs the event loop for `seconds`, so the window is ordered in, laid out and drawn as in the app.
    private static func pump(_ seconds: TimeInterval) {
        let app = NSApplication.shared
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default,
                                         dequeue: true) {
                app.sendEvent(event)
            }
            app.updateWindows()
        } while Date() < deadline
    }

    /// `CGWindowListCreateImage(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> CGImage?`, found at
    /// run time: the macOS 15 SDK marks it unavailable, so naming it would break the build there.
    private typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?

    private static func captureInProcess(_ window: NSWindow, to path: String) -> String {
        // RTLD_DEFAULT is ((void *)-2) on Darwin; Swift does not import the macro.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return "unavailable: CGWindowListCreateImage is not in this macOS"
        }
        let create = unsafeBitCast(symbol, to: WindowImage.self)
        guard let raw = create(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                               CGWindowID(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue)
        else {
            return "failed: no image (Screen Recording permission not granted to this process?)"
        }
        let image = Unmanaged<CGImage>.fromOpaque(raw).takeRetainedValue()
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "failed: PNG encode" }
        do { try data.write(to: URL(fileURLWithPath: path)) }
        catch { return "failed: write \(error.localizedDescription)" }
        let ink = SelfTestRenderCapture.inkFraction(rep)
        // Without the permission macOS can hand back the window frame with its contents blanked.
        let verdict = ink > 0.01 ? "worked" : "failed: the image is blank (Screen Recording permission?)"
        return "\(verdict): \(image.width)x\(image.height) px, ink=\(String(format: "%.3f", ink)) -> \(path)"
    }
}
