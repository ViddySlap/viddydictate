import Foundation

/// Test-only source reads. A stem names every `Sources/App/<stem>*.swift` file, so a self-test that
/// pins controller source keeps working when a later slice splits `DictationController.swift`.
enum SelfTestSource {
    static func read(_ stem: String,
                     root: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                                     isDirectory: true)) -> String {
        let appDir = root.appendingPathComponent("Sources/App", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: appDir.path)) ?? [])
            .filter { $0.hasPrefix(stem) && $0.hasSuffix(".swift") }
            .sorted()
        guard !names.isEmpty else {
            fatalError("SelfTestSource: no file matches stem \"\(stem)\" under \(appDir.path)")
        }
        var text = ""
        for name in names {
            guard let part = try? String(contentsOf: appDir.appendingPathComponent(name, isDirectory: false),
                                         encoding: .utf8) else {
                fatalError("SelfTestSource: stem \"\(stem)\" matched \(name) but it is unreadable under \(appDir.path)")
            }
            text += part
        }
        guard !text.isEmpty else {
            fatalError("SelfTestSource: stem \"\(stem)\" matched \(names.count) file(s) but the text is empty under \(appDir.path)")
        }
        return text
    }
}
