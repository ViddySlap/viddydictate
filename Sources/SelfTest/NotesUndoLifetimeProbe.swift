import Cocoa
import WebKit

/// Offscreen proof of the shipped Sticky Notes island's real navigation path. It loads the bundled index,
/// app.css, theme.css, and app.js in a WKWebView that is never attached to a window; initializes two notes
/// through window.ViddyNotes.receiveState; makes a browser-native contenteditable insertion; switches notes
/// through window.ViddyNotes.externalFocus; and sends the same beforeinput historyUndo event WebKit emits for
/// Cmd+Z. No visible window, OS input event, live store, note file, or control-server port is involved.
enum NotesUndoLifetimeProbe {
    private final class Driver: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private var webView: WKWebView?
        private var ready = false
        private var navigationError: Error?
        private let timeout: TimeInterval = 15

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == NotesBridge.scriptHandler,
                  let payload = message.body as? [String: Any],
                  payload[NotesBridgePayloadKey.type] as? String == NotesInbound.ready.rawValue else { return }
            ready = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            navigationError = error
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            navigationError = error
        }

        private func wait(until condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return condition()
        }

        private func evaluate(_ script: String) -> (Any?, Error?) {
            guard let webView else { return (nil, NSError(domain: "NotesUndoLifetimeProbe", code: 1)) }
            var completed = false
            var output: Any?
            var failure: Error?
            webView.evaluateJavaScript(script) { result, error in
                output = result
                failure = error
                completed = true
            }
            _ = wait { completed }
            return completed ? (output, failure) : (nil, NSError(domain: "NotesUndoLifetimeProbe", code: 2))
        }

        private func pause(_ seconds: TimeInterval = 0.15) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
            }
        }

        private func documentText() -> String? {
            let (result, error) = evaluate("document.querySelector('.cm-content')?.textContent ?? null")
            return error == nil ? result as? String : nil
        }

        func run(resources explicitResources: URL? = nil) -> Bool {
            let resources = explicitResources
                ?? Bundle.main.resourceURL?.appendingPathComponent("StickyNotes", isDirectory: true)
            guard let resources,
                  FileManager.default.fileExists(atPath: resources.appendingPathComponent("index.html").path) else {
                print("[notes-undo-lifetime] FAIL: bundled StickyNotes resources missing")
                return false
            }

            let configuration = WKWebViewConfiguration()
            configuration.userContentController.add(self, name: NotesBridge.scriptHandler)
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 400),
                                 configuration: configuration)
            view.navigationDelegate = self
            webView = view
            view.loadFileURL(resources.appendingPathComponent("index.html"), allowingReadAccessTo: resources)
            guard wait(until: { ready || navigationError != nil }), ready, navigationError == nil else {
                print("[notes-undo-lifetime] FAIL: offscreen island did not become ready")
                return false
            }

            let setup = """
            window.ViddyNotes.receiveState({
              notes: [
                {id: 'note-one', body: '', title: 'One'},
                {id: 'note-two', body: '', title: 'Two'}
              ],
              activeId: 'note-one', history: [], cheatSheetButton: true, retention: 'oneDay'
            });
            """
            guard evaluate(setup).1 == nil else {
                print("[notes-undo-lifetime] FAIL: receiveState bridge setup failed")
                return false
            }

            let type = """
            (function() {
              const content = document.querySelector('.cm-content');
              content.focus();
              return document.execCommand('insertText', false, 'HELLO FROM NOTE ONE');
            })();
            """
            guard evaluate(type).1 == nil else {
                print("[notes-undo-lifetime] FAIL: offscreen editor insertion failed")
                return false
            }
            pause()
            guard documentText() == "HELLO FROM NOTE ONE" else {
                print("[notes-undo-lifetime] FAIL: note one did not receive the reproduction text")
                return false
            }

            guard evaluate("window.ViddyNotes.externalFocus({id:'note-two'});").1 == nil else { return false }
            pause()
            guard documentText() == "" else {
                print("[notes-undo-lifetime] FAIL: note two did not start empty")
                return false
            }

            let undo = """
            (function() {
              const content = document.querySelector('.cm-content');
              content.focus();
              return content.dispatchEvent(new InputEvent('beforeinput', {
                inputType: 'historyUndo', bubbles: true, cancelable: true
              }));
            })();
            """
            for _ in 0..<20 {
                guard evaluate(undo).1 == nil else { return false }
            }
            pause()
            guard documentText() == "" else {
                print("[notes-undo-lifetime] FAIL: note one's text crossed into note two")
                return false
            }

            guard evaluate("window.ViddyNotes.externalFocus({id:'note-one'});").1 == nil else { return false }
            pause()
            guard documentText() == "HELLO FROM NOTE ONE" else {
                print("[notes-undo-lifetime] FAIL: note one lost its body or history on return")
                return false
            }
            guard evaluate(undo).1 == nil else { return false }
            pause()
            guard documentText() == "" else {
                print("[notes-undo-lifetime] FAIL: Cmd+Z did not undo note one's typing after navigation")
                return false
            }

            guard evaluate("window.ViddyNotes.externalFocus({id:'note-two'});").1 == nil else { return false }
            pause()
            guard documentText() == "" else {
                print("[notes-undo-lifetime] FAIL: note two changed after note one's undo")
                return false
            }
            print("[notes-undo-lifetime] PASS: history survived navigation; 20 undos never crossed notes")
            return true
        }
    }

    static func run(resources: URL? = nil) -> Bool { Driver().run(resources: resources) }
}
