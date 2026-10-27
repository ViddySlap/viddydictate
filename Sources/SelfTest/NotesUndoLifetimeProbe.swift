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
        private var savedBodies: [String: String] = [:]
        private let timeout: TimeInterval = 15

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == NotesBridge.scriptHandler,
                  let payload = message.body as? [String: Any],
                  let type = payload[NotesBridgePayloadKey.type] as? String else { return }
            if type == NotesInbound.ready.rawValue { ready = true }
            if type == NotesInbound.save.rawValue,
               let id = payload[NotesBridgePayloadKey.id] as? String,
               let body = payload[NotesBridgePayloadKey.body] as? String {
                savedBodies[id] = body
            }
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

        private func tableJS(_ script: String) -> String? {
            let (result, error) = evaluate(script)
            if let error { return "eval error: \(error.localizedDescription)" }
            return result as? String
        }

        private func tableFail(_ letter: String, _ what: String) -> Bool {
            print("[notes-undo-lifetime] FAIL: table: \(letter) \(what)")
            return false
        }

        private func runTableSequence() -> Bool {
            let fixture = [
                "| Part | What | Time |",
                "|:---|:---:|---:|",
                "| 1 | Try the app | 20 min |",
                "| 2 | Build | 30 |",
                "| 3 | `a|b` in code | 5 min |",
                "| 4 | escaped \\| pipe | 10 min |",
            ].joined(separator: "\n")
            let body = "intro\n" + fixture
            guard let fixtureData = try? JSONEncoder().encode(fixture),
                  let fixtureJSON = String(data: fixtureData, encoding: .utf8) else {
                return tableFail("a", "could not encode the fixture")
            }

            let setup = #"""
            (function() {
              const FIXTURE = \#(fixtureJSON);
              window.__tbl = {
                fixture: FIXTURE,
                body: "intro\n" + FIXTURE,
                press: function(key) {
                  const content = document.querySelector('.cm-content');
                  if (!content) return 'no content';
                  content.focus();
                  content.dispatchEvent(new KeyboardEvent('keydown', { key: key, bubbles: true, cancelable: true }));
                  return 'ok';
                },
                pressMeta: function(key) {
                  const content = document.querySelector('.cm-content');
                  if (!content) return 'no content';
                  content.focus();
                  content.dispatchEvent(new KeyboardEvent('keydown', { key: key, metaKey: true, bubbles: true, cancelable: true }));
                  return 'ok';
                },
                create: function(id, body) {
                  window.ViddyNotes.externalCreate({ id: id, body: body, title: id });
                  return 'ok';
                },
                clickCell: function() {
                  const td = document.querySelector('table.vd-md-table tbody tr td');
                  if (!td) return 'no td';
                  td.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 }));
                  return 'ok';
                },
                clickPaddedCell: function() {
                  const rows = document.querySelectorAll('table.vd-md-table tbody tr');
                  if (rows.length === 0) return 'no rows';
                  const tds = rows[rows.length - 1].querySelectorAll('td');
                  if (tds.length < 2) return 'no second td';
                  tds[1].dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 }));
                  return 'ok';
                }
              };
              return 'ok';
            })()
            """#
            let setupResult = tableJS(setup)
            guard setupResult == "ok" else { return tableFail("a", "setup failed: \(setupResult ?? "nil")") }

            guard tableJS(#"window.__tbl.create('table-note', window.__tbl.body)"#) == "ok" else {
                return tableFail("a", "create table note")
            }
            pause(0.4)
            let a = #"""
            (function() {
              const ts = document.querySelectorAll('table.vd-md-table');
              if (ts.length !== 1) return 'table count ' + ts.length;
              const t = ts[0];
              if (t.querySelectorAll('thead').length !== 1) return 'thead count ' + t.querySelectorAll('thead').length;
              const ths = t.querySelectorAll('thead th');
              const tds = t.querySelectorAll('tbody td');
              if (ths.length !== 3) return 'th count ' + ths.length;
              if (tds.length !== 12) return 'td count ' + tds.length;
              const thTexts = Array.from(ths).map(x => x.textContent).join('|');
              if (thTexts !== 'Part|What|Time') return 'th texts ' + thTexts;
              const tdTexts = Array.from(tds).map(x => x.textContent).join('|');
              if (tdTexts !== '1|Try the app|20 min|2|Build|30|3|`a|b` in code|5 min|4|escaped | pipe|10 min') return 'td texts ' + tdTexts;
              const aligns = Array.from(ths).map(x => x.className).join(',');
              if (aligns !== 'vd-md-align-left,vd-md-align-center,vd-md-align-right') return 'aligns ' + aligns;
              return 'ok';
            })()
            """#
            let aResult = tableJS(a)
            guard aResult == "ok" else { return tableFail("a", aResult ?? "unknown") }

            guard tableJS(#"window.__tbl.clickCell()"#) == "ok" else { return tableFail("b", "click cell") }
            pause()
            let b = #"""
            (function() {
              if (document.querySelector('table.vd-md-table')) return 'table still present';
              const content = document.querySelector('.cm-content');
              if (!content || content.textContent.indexOf('| 1 | Try the app | 20 min |') < 0) return 'raw rows missing';
              const sel = window.getSelection();
              if (!sel || sel.rangeCount === 0) return 'no selection';
              let node = sel.anchorNode;
              while (node && node !== document && !(node.classList && node.classList.contains('cm-line'))) node = node.parentNode;
              if (!node || !node.classList || !node.classList.contains('cm-line')) return 'not in a line';
              if (node.textContent.indexOf('| 1 | Try the app | 20 min |') !== 0) return 'wrong line ' + node.textContent;
              const range = document.createRange();
              range.selectNodeContents(node);
              range.setEnd(sel.anchorNode, sel.anchorOffset);
              if (range.toString().length !== 2) return 'caret offset ' + range.toString().length;
              return 'ok';
            })()
            """#
            let bResult = tableJS(b)
            guard bResult == "ok" else { return tableFail("b", bResult ?? "unknown") }

            guard tableJS(#"window.__tbl.press('ArrowUp'); window.__tbl.press('ArrowUp'); window.__tbl.press('ArrowUp')"#) == "ok" else {
                return tableFail("c", "arrow up")
            }
            pause()
            let c = #"(function() { const ts = document.querySelectorAll('table.vd-md-table'); return ts.length === 1 ? 'ok' : 'table count ' + ts.length; })()"#
            let cResult = tableJS(c)
            guard cResult == "ok" else { return tableFail("c", cResult ?? "unknown") }
            guard savedBodies["table-note"] == body else { return tableFail("c", "source changed after un-render") }

            webView?.setFrameSize(NSSize(width: 400, height: 400))
            pause(0.4)
            guard tableJS(#"window.__tbl.create('wide-note', "intro\n" + ["| C1 | C2 | C3 | C4 | C5 | C6 | C7 | C8 | C9 | C10 |", "|---|---|---|---|---|---|---|---|---|---|", "| 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |"].join("\n"))"#) == "ok" else {
                return tableFail("d", "create wide note")
            }
            pause(0.4)
            let d = #"""
            (function() {
              const wrap = document.querySelector('.vd-md-table-wrap');
              if (!wrap) return 'no wrap';
              if (!(wrap.scrollWidth > wrap.clientWidth)) return 'wrap not scrollable ' + wrap.scrollWidth + '/' + wrap.clientWidth;
              const scroller = document.querySelector('.cm-scroller');
              if (scroller && scroller.scrollWidth > scroller.clientWidth) return 'scroller overflows ' + scroller.scrollWidth + '/' + scroller.clientWidth;
              const main = document.getElementById('main');
              if (main && main.scrollWidth > main.clientWidth) return 'main overflows ' + main.scrollWidth + '/' + main.clientWidth;
              return 'ok';
            })()
            """#
            let dResult = tableJS(d)
            guard dResult == "ok" else { return tableFail("d", dResult ?? "unknown") }

            guard tableJS(#"window.__tbl.create('html-note', "intro\n" + ["| HTML |", "|---|", "| <b>x</b> |"].join("\n"))"#) == "ok" else {
                return tableFail("e", "create html note")
            }
            pause(0.4)
            let e = #"""
            (function() {
              const t = document.querySelector('table.vd-md-table');
              if (!t) return 'no table';
              if (t.querySelectorAll('b').length !== 0) return 'b element created';
              const td = t.querySelector('tbody td');
              if (!td || td.textContent !== '<b>x</b>') return 'td text ' + (td ? td.textContent : 'none');
              return 'ok';
            })()
            """#
            let eResult = tableJS(e)
            guard eResult == "ok" else { return tableFail("e", eResult ?? "unknown") }

            guard tableJS(#"window.__tbl.create('arrow-note', window.__tbl.body)"#) == "ok" else {
                return tableFail("f", "create arrow note")
            }
            pause(0.4)
            let fBefore = #"(function() { return document.querySelectorAll('table.vd-md-table').length === 1 ? 'ok' : 'not rendered before ArrowDown'; })()"#
            let fBeforeResult = tableJS(fBefore)
            guard fBeforeResult == "ok" else { return tableFail("f", fBeforeResult ?? "unknown") }
            guard tableJS(#"window.__tbl.press('ArrowDown')"#) == "ok" else { return tableFail("f", "arrow down") }
            pause()
            let fAfter = #"(function() { return document.querySelector('table.vd-md-table') ? 'table still present' : 'ok'; })()"#
            let fAfterResult = tableJS(fAfter)
            guard fAfterResult == "ok" else { return tableFail("f", fAfterResult ?? "unknown") }
            let fCaret = #"""
            (function() {
              const sel = window.getSelection();
              if (!sel || sel.rangeCount === 0) return 'no selection';
              let node = sel.anchorNode;
              while (node && node !== document && !(node.classList && node.classList.contains('cm-line'))) node = node.parentNode;
              if (!node || !node.classList || !node.classList.contains('cm-line')) return 'not in a line';
              const header = window.__tbl.fixture.split('\n')[0];
              if (node.textContent.indexOf(header) !== 0) return 'wrong line ' + node.textContent;
              const before = document.createRange();
              before.selectNodeContents(node);
              before.setEnd(sel.anchorNode, sel.anchorOffset);
              if (before.toString().length !== 0) return 'caret offset ' + before.toString().length;
              return 'ok';
            })()
            """#
            let fCaretResult = tableJS(fCaret)
            guard fCaretResult == "ok" else { return tableFail("f caret ", fCaretResult ?? "unknown") }

            guard tableJS(#"window.__tbl.create('arrowup-note', window.__tbl.body + "\nafter")"#) == "ok" else {
                return tableFail("f up ", "create arrowup note")
            }
            pause(0.4)
            let fUpBefore = #"(function() { return document.querySelectorAll('table.vd-md-table').length === 1 ? 'ok' : 'not rendered before Cmd+ArrowDown'; })()"#
            let fUpBeforeResult = tableJS(fUpBefore)
            guard fUpBeforeResult == "ok" else { return tableFail("f up ", fUpBeforeResult ?? "unknown") }
            guard tableJS(#"window.__tbl.pressMeta('ArrowDown')"#) == "ok" else { return tableFail("f up ", "cmd arrow down") }
            pause()
            let fUpStill = #"(function() { return document.querySelectorAll('table.vd-md-table').length === 1 ? 'ok' : 'table gone after Cmd+ArrowDown'; })()"#
            let fUpStillResult = tableJS(fUpStill)
            guard fUpStillResult == "ok" else { return tableFail("f up ", fUpStillResult ?? "unknown") }
            guard tableJS(#"window.__tbl.press('ArrowUp')"#) == "ok" else { return tableFail("f up ", "arrow up") }
            pause()
            let fUpAfter = #"""
            (function() {
              if (document.querySelector('table.vd-md-table')) return 'table still present after ArrowUp';
              const sel = window.getSelection();
              if (!sel || sel.rangeCount === 0) return 'no selection';
              let node = sel.anchorNode;
              while (node && node !== document && !(node.classList && node.classList.contains('cm-line'))) node = node.parentNode;
              if (!node || !node.classList || !node.classList.contains('cm-line')) return 'not in a line';
              const lastRow = window.__tbl.fixture.split('\n').pop();
              if (node.textContent.indexOf(lastRow) !== 0) return 'wrong line ' + node.textContent;
              return 'ok';
            })()
            """#
            let fUpAfterResult = tableJS(fUpAfter)
            guard fUpAfterResult == "ok" else { return tableFail("f up ", fUpAfterResult ?? "unknown") }

            guard tableJS(#"window.__tbl.create('bull-note', window.__tbl.body)"#) == "ok" else {
                return tableFail("g", "create bullseye note")
            }
            pause(0.4)
            let gBefore = #"(function() { return document.querySelectorAll('table.vd-md-table').length === 1 ? 'ok' : 'not rendered before arm'; })()"#
            let gBeforeResult = tableJS(gBefore)
            guard gBeforeResult == "ok" else { return tableFail("g", gBeforeResult ?? "unknown") }
            guard tableJS(#"(function(){ window.ViddyNotes.bullseyeArmed({ id: 'bull-note', anchor: window.__tbl.body.indexOf('What'), enabled: true }); return 'ok'; })()"#) == "ok" else {
                return tableFail("g", "arm bullseye")
            }
            pause()
            let gArmed = #"(function() { return document.querySelector('table.vd-md-table') ? 'table still present' : 'ok'; })()"#
            let gArmedResult = tableJS(gArmed)
            guard gArmedResult == "ok" else { return tableFail("g", gArmedResult ?? "unknown") }
            guard tableJS(#"(function(){ window.ViddyNotes.bullseyeArmed({ id: 'bull-note', anchor: window.__tbl.body.indexOf('What'), enabled: false }); return 'ok'; })()"#) == "ok" else {
                return tableFail("g", "disarm bullseye")
            }
            pause()
            let gAfter = #"(function() { return document.querySelectorAll('table.vd-md-table').length === 1 ? 'ok' : 'not re-rendered after disarm'; })()"#
            let gAfterResult = tableJS(gAfter)
            guard gAfterResult == "ok" else { return tableFail("g", gAfterResult ?? "unknown") }
            guard savedBodies["bull-note"] == body else { return tableFail("g", "source changed by bullseye") }

            guard tableJS(#"window.__tbl.create('undo-note', window.__tbl.body)"#) == "ok" else {
                return tableFail("h", "create undo note")
            }
            pause(0.4)
            guard tableJS(#"""
            (function() {
              const content = document.querySelector('.cm-content');
              if (!content) return 'no content';
              content.focus();
              document.execCommand('insertText', false, 'X');
              return 'ok';
            })()
            """#) == "ok" else { return tableFail("h", "type on line above") }
            pause(0.4)
            guard tableJS(#"window.__tbl.clickCell()"#) == "ok" else { return tableFail("h", "enter 1") }
            guard tableJS(#"window.__tbl.press('ArrowUp'); window.__tbl.press('ArrowUp'); window.__tbl.press('ArrowUp')"#) == "ok" else { return tableFail("h", "leave 1") }
            guard tableJS(#"window.__tbl.clickCell()"#) == "ok" else { return tableFail("h", "enter 2") }
            guard tableJS(#"window.__tbl.press('ArrowUp'); window.__tbl.press('ArrowUp'); window.__tbl.press('ArrowUp')"#) == "ok" else { return tableFail("h", "leave 2") }
            pause()
            guard tableJS(#"""
            (function() {
              const content = document.querySelector('.cm-content');
              if (!content) return 'no content';
              content.focus();
              content.dispatchEvent(new InputEvent('beforeinput', { inputType: 'historyUndo', bubbles: true, cancelable: true }));
              return 'ok';
            })()
            """#) == "ok" else { return tableFail("h", "undo") }
            pause(0.4)
            guard savedBodies["undo-note"] == body else {
                return tableFail("h", "typed character survived one undo (render added history)")
            }

            guard tableJS(#"window.__tbl.create('short-note', "intro\n| A | B | C |\n|---|---|---|\n| 1 | 2 | 3 |\n| 4 |")"#) == "ok" else {
                return tableFail("b short ", "create short note")
            }
            pause(0.4)
            let bShortBefore = #"""
            (function() {
              const ts = document.querySelectorAll('table.vd-md-table');
              if (ts.length !== 1) return 'table count ' + ts.length;
              const rows = ts[0].querySelectorAll('tbody tr');
              const last = rows[rows.length - 1];
              if (!last) return 'no last row';
              if (last.querySelectorAll('td').length !== 3) return 'last row td count ' + last.querySelectorAll('td').length;
              return 'ok';
            })()
            """#
            let bShortBeforeResult = tableJS(bShortBefore)
            guard bShortBeforeResult == "ok" else { return tableFail("b short ", bShortBeforeResult ?? "unknown") }

            guard tableJS(#"window.__tbl.clickPaddedCell()"#) == "ok" else { return tableFail("b short ", "click padded cell") }
            pause()
            let bShortAfter = #"""
            (function() {
              if (document.querySelector('table.vd-md-table')) return 'table still present';
              const sel = window.getSelection();
              if (!sel || sel.rangeCount === 0) return 'no selection';
              let node = sel.anchorNode;
              while (node && node !== document && !(node.classList && node.classList.contains('cm-line'))) node = node.parentNode;
              if (!node || !node.classList || !node.classList.contains('cm-line')) return 'not in a line';
              if (node.textContent !== '| 4 |') return 'wrong line ' + node.textContent;
              const range = document.createRange();
              range.selectNodeContents(node);
              range.setEnd(sel.anchorNode, sel.anchorOffset);
              if (range.toString().length !== 5) return 'caret offset ' + range.toString().length;
              return 'ok';
            })()
            """#
            let bShortAfterResult = tableJS(bShortAfter)
            guard bShortAfterResult == "ok" else { return tableFail("b short ", bShortAfterResult ?? "unknown") }

            print("[notes-undo-lifetime] table PASS: renders, enters, leaves, scrolls, bullseye, and undo isolation")
            return true
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
            guard runTableSequence() else { return false }
            print("[notes-undo-lifetime] PASS: history survived navigation; 20 undos never crossed notes")
            return true
        }
    }

    static func run(resources: URL? = nil) -> Bool { Driver().run(resources: resources) }
}
