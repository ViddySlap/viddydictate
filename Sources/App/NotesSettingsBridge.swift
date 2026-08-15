import Foundation
import WebKit

enum NotesSettingsBridge {
    enum HistoryEffect {
        case none
        case refresh
    }

    static func applyTheme(to webView: WKWebView?, pageReady: Bool) {
        guard let webView = webView, pageReady else { return }
        let css = Phosphor.emitThemeCSS()
        guard let data = try? JSONSerialization.data(withJSONObject: [css]),
              let arr = String(data: data, encoding: .utf8) else { return }
        let literal = String(arr.dropFirst().dropLast())
        let js = """
        (function(){var id='vd-theme-override';var el=document.getElementById(id);
        if(!el){el=document.createElement('style');el.id=id;document.head.appendChild(el);}
        el.textContent=\(literal);})();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    static func payload() -> [String: Any] {
        [
            NotesBridgePayloadKey.cheatSheetButton: Settings.stickyNotesCheatSheetButton,
            NotesBridgePayloadKey.retention: Settings.stickyNotesRetention.rawValue,
        ]
    }

    static func applyInbound(
        _ type: NotesInbound, payload: [String: Any], store: StickyNotesStore
    ) -> HistoryEffect {
        switch type {
        case .setRetention:
            guard let raw = payload[NotesBridgePayloadKey.retention] as? String,
                  let retention = StickyNotesRetention(rawValue: raw) else { return .none }
            store.setRetention(retention)
            return .refresh
        case .setCheatSheetButton:
            guard let enabled = payload[NotesBridgePayloadKey.enabled] as? Bool else { return .none }
            Settings.stickyNotesCheatSheetButton = enabled
            return .none
        default:
            return .none
        }
    }
}
