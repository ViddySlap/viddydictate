import Darwin
import CryptoKit
import Foundation

// External steady-state boundary for ViddyDictate's future authenticated Codex transform. The model
// process receives user text only through inherited stdin. Optional L11 frames arrive only as bounded,
// app-staged files under the dedicated cwd. This runner never logs stdin/stdout, and its production argv
// contains only app-owned paths, a content-hashed profile name, and fixed policy values.

private let sandboxExec = "/usr/bin/sandbox-exec"
private let schemaFilename = "transform-output.schema.json"
private let allowedConnectTargets: Set<String> = ["api.openai.com:443", "chatgpt.com:443"]

private enum RunnerError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let message) = self { return message }; return "runner error" }
}

private struct Roots {
    let home: String
    let cwd: String
    let temp: String

    var schema: String { home + "/" + schemaFilename }
    var config: String { home + "/config.toml" }
    func profilePath(_ name: String) -> String { home + "/" + name + ".config.toml" }
}

private func childEnvironment(
    roots: Roots,
    home: String,
    proxyURL: String? = nil
) throws -> [String: String] {
    let roots = try canonicalRoots(roots)
    let home = try canonicalExistingPath(home)
    var environment = [
        "HOME": home,
        "CODEX_HOME": roots.home,
        "PATH": "/usr/bin:/bin",
        "TMPDIR": roots.temp + "/",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "TERM": "dumb",
    ]
    if let proxyURL {
        environment["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        environment["HTTPS_PROXY"] = proxyURL
        environment["https_proxy"] = proxyURL
        environment["HTTP_PROXY"] = proxyURL
        environment["http_proxy"] = proxyURL
        environment["NO_PROXY"] = ""
        environment["no_proxy"] = ""
    }
    return environment
}

private func environmentEntries(_ environment: [String: String]) -> [String] {
    environment.map { "\($0.key)=\($0.value)" }.sorted()
}

private func canonicalExistingPath(_ path: String) throws -> String {
    guard path.hasPrefix("/"),
          let resolved = path.withCString({ realpath($0, nil) }) else {
        throw RunnerError.failed("containment path canonicalization failed")
    }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func canonicalRoots(_ roots: Roots) throws -> Roots {
    Roots(
        home: try canonicalExistingPath(roots.home),
        cwd: try canonicalExistingPath(roots.cwd),
        temp: try canonicalExistingPath(roots.temp))
}

private func canonicalPathWithExistingParent(_ path: String) throws -> String {
    let leaf = URL(fileURLWithPath: path).lastPathComponent
    guard !leaf.isEmpty, leaf != ".", leaf != ".." else {
        throw RunnerError.failed("containment path canonicalization failed")
    }
    let parent = (path as NSString).deletingLastPathComponent
    let canonicalParent = try canonicalExistingPath(parent)
    return (canonicalParent as NSString).appendingPathComponent(leaf)
}

private func isAuthorizedSyntheticScratchPath(_ path: String) throws -> Bool {
    let candidate = try canonicalPathWithExistingParent(path)
    let systemTemp = try canonicalExistingPath("/private/tmp")
    return candidate.hasPrefix(
        systemTemp + "/viddydictate-codex-")
}

private struct ExpectedExecutableIdentity: Equatable {
    let sha256: String
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

private func measuredExecutableIdentity(_ executable: String)
    throws -> ExpectedExecutableIdentity {
    var st = stat()
    guard lstat(executable, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
        throw RunnerError.failed("could not measure executable identity")
    }
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: executable))
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 1_048_576) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
    }
    return ExpectedExecutableIdentity(
        sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
        device: UInt64(st.st_dev),
        inode: UInt64(st.st_ino),
        size: Int64(st.st_size),
        modifiedSeconds: Int64(st.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int64(st.st_mtimespec.tv_nsec))
}

private func expectedExecutableIdentity(_ arguments: [String]) throws
    -> ExpectedExecutableIdentity {
    guard let sha256 = value("--binary-sha256", in: arguments),
          sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
          let deviceText = value("--binary-device", in: arguments),
          let device = UInt64(deviceText),
          let inodeText = value("--binary-inode", in: arguments),
          let inode = UInt64(inodeText),
          let sizeText = value("--binary-size", in: arguments),
          let size = Int64(sizeText),
          let secondsText = value("--binary-mtime-sec", in: arguments),
          let modifiedSeconds = Int64(secondsText),
          let nanosecondsText = value("--binary-mtime-nsec", in: arguments),
          let modifiedNanoseconds = Int64(nanosecondsText) else {
        throw RunnerError.failed("missing exact-binary compatibility identity")
    }
    return ExpectedExecutableIdentity(
        sha256: sha256,
        device: device,
        inode: inode,
        size: size,
        modifiedSeconds: modifiedSeconds,
        modifiedNanoseconds: modifiedNanoseconds)
}

private func receiptBoundExecutable(_ arguments: [String]) throws -> String {
    guard let path = value("--binary-path", in: arguments),
          path.hasPrefix("/"),
          URL(fileURLWithPath: path).lastPathComponent.range(
            of: #"^codex-[0-9a-f]{64}$"#,
            options: .regularExpression) != nil else {
        throw RunnerError.failed("missing receipt-bound executable snapshot")
    }
    var st = stat()
    guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
        throw RunnerError.failed("missing receipt-bound executable snapshot")
    }
    return try canonicalExistingPath(path)
}

private func validateExecutableIdentity(
    _ expected: ExpectedExecutableIdentity,
    executable: String
) throws {
    var st = stat()
    guard lstat(executable, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
          UInt64(st.st_dev) == expected.device,
          UInt64(st.st_ino) == expected.inode,
          Int64(st.st_size) == expected.size,
          Int64(st.st_mtimespec.tv_sec) == expected.modifiedSeconds,
          Int64(st.st_mtimespec.tv_nsec) == expected.modifiedNanoseconds else {
        throw RunnerError.failed("Codex executable identity changed")
    }
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: executable))
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 1_048_576) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
    }
    let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard hash == expected.sha256 else {
        throw RunnerError.failed("Codex executable identity changed")
    }
}

private func identityArguments(_ identity: ExpectedExecutableIdentity) -> [String] {
    [
        "--binary-sha256", identity.sha256,
        "--binary-device", String(identity.device),
        "--binary-inode", String(identity.inode),
        "--binary-size", String(identity.size),
        "--binary-mtime-sec", String(identity.modifiedSeconds),
        "--binary-mtime-nsec", String(identity.modifiedNanoseconds),
    ]
}

private enum SandboxPolicy {
    static func build(roots: Roots, executable: String, proxyPort: UInt16) throws -> String {
        for path in [roots.home, roots.cwd, roots.temp, executable] where !path.hasPrefix("/") {
            throw RunnerError.failed("containment path is not absolute")
        }
        let asPassedRoots = roots
        let roots = try canonicalRoots(roots)
        let port = Int(proxyPort)
        guard port > 0 else { throw RunnerError.failed("containment proxy port is invalid") }
        let ancestorMetadata = try metadataAncestors(
            roots: asPassedRoots, executable: executable)
            .map { "            (literal \(literal($0)))" }
            .joined(separator: "\n")
        return """
        (version 1)
        (deny default)

        ; sandbox-exec needs a self-targeted fork permission for its initial filtered exec. The only
        ; executable permitted after that transition is the pinned Codex binary; no shell or other
        ; process image can be launched.
        (allow process-fork (target self))
        (allow process-exec (literal \(literal(executable))))
        (allow process-info* (target self))
        (allow signal (target self))
        (allow sysctl-read)

        ; Runtime/loader/trust material plus the three dedicated roots. No other user path is readable.
        (allow file-read-metadata
            (literal "/")
        \(ancestorMetadata)
            (literal "/etc")
            (literal "/etc/codex")
            (literal "/etc/ssl")
            (literal "/private")
            (literal "/private/etc")
            (literal "/private/etc/codex")
            (literal "/private/etc/ssl")
            (literal "/Applications")
            (literal "/Applications/ChatGPT.app")
            (literal "/Applications/ChatGPT.app/Contents")
            (literal "/Applications/ChatGPT.app/Contents/Resources")
            (subpath "/System")
            (subpath "/usr/lib")
            (subpath "/Library/Apple/System")
            (subpath \(literal(roots.home)))
            (subpath \(literal(roots.cwd)))
            (subpath \(literal(roots.temp))))
        (allow file-read*
            (literal "/")
            (literal "/etc")
            (literal "/etc/codex/requirements.toml")
            (literal "/etc/ssl")
            (literal "/private/etc/codex/requirements.toml")
            (literal "/private/etc/ssl")
            (literal \(literal(executable)))
            (literal "/dev/null")
            (literal "/dev/urandom")
            (literal "/private/etc/ssl/cert.pem")
            (literal "/etc/ssl/cert.pem")
            (subpath "/System")
            (subpath "/usr/lib")
            (subpath "/Library/Apple/System")
            (subpath \(literal(roots.home)))
            (subpath \(literal(roots.cwd)))
            (subpath \(literal(roots.temp))))
        (allow file-write*
            (literal "/dev/null")
            (subpath \(literal(roots.home)))
            (subpath \(literal(roots.temp))))

        ; Codex cannot open arbitrary Internet, LAN, loopback, or Unix-socket destinations. Its sole network
        ; route is the runner-owned authenticated CONNECT proxy on this one ephemeral loopback port.
        (allow network-outbound (remote tcp "localhost:\(port)"))

        ; TLS trust evaluation may use trustd. Auth remains a file inside the dedicated CODEX_HOME.
        (allow mach-lookup
            (global-name "com.apple.SystemConfiguration.configd")
            (global-name "com.apple.trustd")
            (global-name "com.apple.trustd.agent"))
        """
    }

    static func buildQuarantine(roots: Roots, executable: String) throws -> String {
        let networked = try build(roots: roots, executable: executable, proxyPort: 43117)
        return networked.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("(allow network-outbound") }
            .joined(separator: "\n")
    }

    static func auditQuarantine(_ policy: String, roots: Roots, executable: String) throws {
        let asPassedRoots = roots
        let roots = try canonicalRoots(roots)
        let required = [
            "(deny default)",
            "(allow process-fork (target self))",
            "(allow process-exec (literal \(literal(executable))))",
            "(subpath \(literal(roots.home)))",
            "(subpath \(literal(roots.cwd)))",
            "(subpath \(literal(roots.temp)))",
        ]
        guard required.allSatisfy(policy.contains),
              !policy.contains("(allow network-outbound"),
              !policy.contains("(allow network-inbound") else {
            throw RunnerError.failed(
                "quarantine containment policy is not deny-network exact")
        }
        for ancestor in try metadataAncestors(
            roots: asPassedRoots, executable: executable) {
            guard policy.contains("(literal \(literal(ancestor)))") else {
                throw RunnerError.failed(
                    "quarantine containment is missing exact ancestor metadata")
            }
        }
    }

    static func audit(_ policy: String, roots: Roots, executable: String, proxyPort: UInt16) throws {
        let asPassedRoots = roots
        let roots = try canonicalRoots(roots)
        let required = [
            "(deny default)",
            "(allow process-fork (target self))",
            "(allow process-exec (literal \(literal(executable))))",
            "(allow file-read*",
            "(literal \"/\")",
            "(literal \"/etc/codex/requirements.toml\")",
            "(literal \"/private/etc/codex/requirements.toml\")",
            "(global-name \"com.apple.SystemConfiguration.configd\")",
            "(subpath \(literal(roots.home)))",
            "(subpath \(literal(roots.cwd)))",
            "(subpath \(literal(roots.temp)))",
            "(allow network-outbound (remote tcp \"localhost:\(proxyPort)\"))",
        ]
        guard required.allSatisfy(policy.contains) else {
            throw RunnerError.failed("containment policy is missing a required exact rule")
        }
        for forbidden in [
            "(allow network-outbound)", "remote tcp \"*:443\"", "remote tcp \"*:*\"",
            "(allow network-inbound", "(allow process*)", "(allow process-fork)",
            "(subpath \"/Users\")", "(subpath \"/private\")",
        ] where policy.contains(forbidden) {
            throw RunnerError.failed("containment policy contains a broad rule")
        }
        let networkRules = policy.components(separatedBy: "(allow network-outbound").count - 1
        guard networkRules == 1 else { throw RunnerError.failed("containment has ambiguous network rules") }
        let rootLiteralRules = policy.components(separatedBy: "(literal \"/\")").count - 1
        guard rootLiteralRules == 2 else { throw RunnerError.failed("containment root literal is ambiguous") }
        for ancestor in try metadataAncestors(
            roots: asPassedRoots, executable: executable) {
            guard policy.contains("(literal \(literal(ancestor)))") else {
                throw RunnerError.failed("containment is missing exact ancestor metadata")
            }
        }
    }

    private static func metadataAncestors(
        roots: Roots,
        executable: String
    ) throws -> [String] {
        var result: Set<String> = []
        func addAncestors(of path: String) {
            var current = (path as NSString).deletingLastPathComponent
            while current != "/" && !current.isEmpty {
                result.insert(current)
                let parent = (current as NSString).deletingLastPathComponent
                if parent == current { break }
                current = parent
            }
        }
        for path in [roots.home, roots.cwd, roots.temp, executable] {
            addAncestors(of: path)
            addAncestors(of: try canonicalExistingPath(path))
        }
        return result.sorted()
    }

    private static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

private enum ConnectPolicy {
    static func authorizationValue(token: String) -> String {
        let raw = Data("viddydictate:\(token)".utf8).base64EncodedString()
        return "Basic \(raw)"
    }

    static func authorizedTarget(header: Data, token: String) -> String? {
        guard header.count <= 8192,
              let text = String(data: header, encoding: .utf8),
              text.hasSuffix("\r\n\r\n") else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let fields = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3, fields[0] == "CONNECT",
              fields[2] == "HTTP/1.1" || fields[2] == "HTTP/1.0" else { return nil }
        let target = String(fields[1]).lowercased()
        guard allowedConnectTargets.contains(target) else { return nil }

        var authorization: String?
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "proxy-authorization" {
                guard authorization == nil else { return nil }
                authorization = value
            }
        }
        guard authorization == authorizationValue(token: token) else { return nil }
        return target
    }
}

private final class TCPListener {
    let descriptor: Int32
    let port: UInt16
    private var accepting = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RunnerError.failed("loopback listener socket failed") }
        var yes: Int32 = 1
        _ = withUnsafePointer(to: &yes) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw RunnerError.failed("loopback listener bind denied")
        }
        var bound = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard nameResult == 0 else {
            close(fd)
            throw RunnerError.failed("loopback listener address lookup failed")
        }
        descriptor = fd
        port = UInt16(bigEndian: bound.sin_port)
    }

    func start(handler: @escaping (Int32) -> Void) {
        accepting = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while self.accepting {
                let client = accept(self.descriptor, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                DispatchQueue.global(qos: .utility).async { handler(client) }
            }
        }
    }

    func stop() {
        accepting = false
        _ = shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }

    deinit { if accepting { stop() } }
}

private final class AllowlistedConnectProxy {
    let listener: TCPListener
    let token: String

    init() throws {
        listener = try TCPListener()
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    func start() {
        listener.start { [token] client in
            defer { close(client) }
            guard let header = readHeader(client),
                  let target = ConnectPolicy.authorizedTarget(header: header, token: token) else {
                sendAll(client, Data("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n".utf8))
                return
            }
            let host = String(target.dropLast(4)) // every permitted target ends in :443
            guard let upstream = connectTCP(host: host, port: 443) else {
                sendAll(client, Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
                return
            }
            defer { close(upstream) }
            sendAll(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                relay(from: client, to: upstream)
                _ = shutdown(upstream, SHUT_WR)
                group.leave()
            }
            relay(from: upstream, to: client)
            _ = shutdown(client, SHUT_WR)
            group.wait()
        }
    }

    var proxyURL: String { "http://viddydictate:\(token)@127.0.0.1:\(listener.port)" }
    func stop() { listener.stop() }
}

private func readHeader(_ fd: Int32) -> Data? {
    var data = Data(), byte = UInt8(0)
    while data.count < 8192 {
        let count = Darwin.read(fd, &byte, 1)
        if count != 1 { return nil }
        data.append(byte)
        if data.count >= 4 && data.suffix(4) == Data([13, 10, 13, 10]) { return data }
    }
    return nil
}

private func sendAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        while sent < raw.count {
            let count = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
            if count <= 0 { return }
            sent += count
        }
    }
}

private func relay(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = Darwin.read(source, &buffer, buffer.count)
        if count <= 0 { return }
        var sent = 0
        while sent < count {
            let n = buffer.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.send(destination, base.advanced(by: sent), count - sent, 0)
            }
            if n <= 0 { return }
            sent += n
        }
    }
}

private func connectTCP(host: String, port: UInt16) -> Int32? {
    var hints = addrinfo(
        ai_flags: AI_ADDRCONFIG,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return nil }
    defer { freeaddrinfo(result) }
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let info = cursor {
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd >= 0 {
            if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { return fd }
            close(fd)
        }
        cursor = info.pointee.ai_next
    }
    return nil
}

private func parseRoots(_ arguments: [String]) throws -> Roots {
    guard let home = value("--home", in: arguments),
          let cwd = value("--cwd", in: arguments),
          let temp = value("--tmp", in: arguments) else {
        throw RunnerError.failed("missing dedicated root argument")
    }
    return Roots(home: home, cwd: cwd, temp: temp)
}

private func value(_ flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

private func values(_ flag: String, in arguments: [String]) -> [String] {
    arguments.indices.compactMap { index in
        guard arguments[index] == flag, arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

/// The sterile-cwd rule, as a value so it can be gated without a staged containment root.
///
/// The cwd Codex is given must hold NOTHING the app did not put there on purpose. Before 2026-08-12 that
/// was expressed as "empty", which silently made the runner's own image-input feature unusable: the app
/// stages `vd-input-image-NN.ext` into exactly this directory before calling `exec`, so every attachment-
/// carrying request threw `sterile cwd is not empty` and exited 1 without ever launching Codex. The fixture
/// covering the image path used a fake runner, so nothing ran this check on the path that needed it.
///
/// The invariant is unchanged in strength: entries must be a subset of the image names named on argv, and
/// every one of those names has already had to match the strict `vd-input-image-NN.ext` pattern before it
/// is offered here. `runPreflight` passes nothing, so preflight still demands a literally empty cwd.
func sterileCwdIsIntact(entries: [String], allowed: Set<String>) -> Bool {
    Set(entries).isSubset(of: allowed)
}

private func validateRoots(_ roots: Roots, profile: String, executable: String,
                           allowedCwdEntries: Set<String> = []) throws {
    guard profile.range(of: #"^route-[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
        throw RunnerError.failed("profile name is not a complete content hash")
    }
    for directory in [roots.home, roots.cwd, roots.temp] { try requireMode(directory, kind: S_IFDIR, mode: 0o700) }
    try requireMode(roots.config, kind: S_IFREG, mode: 0o400)
    try requireMode(roots.schema, kind: S_IFREG, mode: 0o400)
    let profilePath = roots.profilePath(profile)
    try requireMode(profilePath, kind: S_IFREG, mode: 0o400)
    let profileBytes = try Data(contentsOf: URL(fileURLWithPath: profilePath))
    let profileHash = SHA256.hash(data: profileBytes).map { String(format: "%02x", $0) }.joined()
    guard profile == "route-\(profileHash)" else {
        throw RunnerError.failed("profile bytes do not match the immutable content-hash name")
    }
    try validateCanonicalProfile(profileBytes)
    guard sterileCwdIsIntact(
            entries: try FileManager.default.contentsOfDirectory(atPath: roots.cwd),
            allowed: allowedCwdEntries) else {
        throw RunnerError.failed("sterile cwd is not empty")
    }
    guard FileManager.default.isExecutableFile(atPath: executable),
          FileManager.default.isExecutableFile(atPath: sandboxExec) else {
        throw RunnerError.failed("pinned containment executable is missing")
    }
}

/// Route profiles are the only request-specific configuration accepted by the runner. Validate the
/// exact canonical four-field shape before Codex reads it so a content-hashed but capability-broadening
/// TOML file cannot become a production transform profile. Developer text remains inside the file and
/// never enters runner/Codex argv.
private func validateCanonicalProfile(_ data: Data) throws {
    guard let text = String(data: data, encoding: .utf8) else {
        throw RunnerError.failed("route profile is not UTF-8")
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.count == 5, lines[4].isEmpty,
          lines[0].hasPrefix("# viddydictate-envelope-version = \""),
          lines[1].hasPrefix("model = \""),
          lines[2].hasPrefix("model_reasoning_effort = \""),
          lines[3].hasPrefix("developer_instructions = \"") else {
        throw RunnerError.failed("route profile canonical shape changed")
    }
    for line in lines.prefix(4) {
        guard line.hasSuffix("\""), !line.contains("\u{0}") else {
            throw RunnerError.failed("route profile canonical value is invalid")
        }
    }
    let identifierPattern = #"^[A-Za-z0-9._-]+$"#
    for (line, prefix) in [
        (lines[0], "# viddydictate-envelope-version = \""),
        (lines[1], "model = \""),
        (lines[2], "model_reasoning_effort = \""),
    ] {
        let value = String(line.dropFirst(prefix.count).dropLast())
        guard value.range(of: identifierPattern, options: .regularExpression) != nil else {
            throw RunnerError.failed("route profile identifier is invalid")
        }
    }
    guard lines[3].count > "developer_instructions = \"\"".count else {
        throw RunnerError.failed("route profile developer instructions are empty")
    }
}

private func requireMode(_ path: String, kind: mode_t, mode: mode_t) throws {
    var st = stat()
    guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == kind, (st.st_mode & 0o777) == mode else {
        throw RunnerError.failed("containment path type/mode mismatch")
    }
}

private func runPreflight(arguments: [String]) throws {
    let roots = try parseRoots(arguments)
    let executable = try receiptBoundExecutable(arguments)
    let expectedIdentity = try expectedExecutableIdentity(arguments)
    try validateExecutableIdentity(expectedIdentity, executable: executable)
    guard let profile = value("--profile", in: arguments) else { throw RunnerError.failed("missing profile") }
    try validateRoots(roots, profile: profile, executable: executable)
    let policy = try SandboxPolicy.build(roots: roots, executable: executable, proxyPort: 43117)
    try SandboxPolicy.audit(policy, roots: roots, executable: executable, proxyPort: 43117)
    print("[codex-containment] deny-default filesystem policy pinned")
    print("[codex-containment] network=authenticated_local_CONNECT_proxy targets=api.openai.com:443,chatgpt.com:443")
    print("[codex-containment] text_stdin_only=true app_staged_images=true argv_payload=false process_group_watchdog=true")
}

/// The only filename shape the app may stage into the sterile cwd.
let stagedImageNamePattern = #"^vd-input-image-[0-9]{2}\.(png|jpg|gif|webp)$"#

/// The exact Codex argv one contained transform runs, images included. Pure, so the deterministic runner
/// selftest can pin the property below without a staged containment root or a provider call.
///
/// IMAGES MUST FOLLOW THE SUBCOMMAND. `-i/--image` is declared `<FILE>...`, i.e. variadic, so placing it
/// among the global options ahead of `exec` makes the parser eat `exec` as a second filename; the run then
/// has no subcommand at all and dies on the first flag only `exec` accepts:
///
///     error: unexpected argument '--ephemeral' found
///
/// That is the second half of the 2026-08-12 cloud sticky-skill defect, and it was latent behind the first
/// half (the sterile-cwd throw above, which exited before Codex ever launched). The `--image=<path>` form
/// is used rather than `-i <path>` so a single value is bound by construction and no neighbouring token can
/// be absorbed regardless of where the flag sits.
func codexExecArguments(executable: String, profile: String, cwd: String, schema: String,
                        imagePaths: [String]) -> [String] {
    var codexArguments = [
        executable,
        "-p", profile,
        "-s", "read-only",
        "-a", "never",
        "-C", cwd,
        "exec", "--strict-config", "--ephemeral", "--ignore-rules", "--skip-git-repo-check",
    ]
    for path in imagePaths { codexArguments.append("--image=" + path) }
    codexArguments += ["--json", "--output-schema", schema, "-"]
    return codexArguments
}

private func runExec(arguments: [String]) throws -> Int32 {
    let roots = try parseRoots(arguments)
    let executable = try receiptBoundExecutable(arguments)
    let expectedIdentity = try expectedExecutableIdentity(arguments)
    try validateExecutableIdentity(expectedIdentity, executable: executable)
    guard let profile = value("--profile", in: arguments) else { throw RunnerError.failed("missing profile") }

    // The image names are read and pattern-checked BEFORE the roots are validated, because they are the
    // only entries the sterile cwd may legally contain: the app stages them there for this call. Every
    // other property of each file is still proven below, against the staged file itself.
    let imageNames = values("--image", in: arguments)
    let imageFlagCount = arguments.filter { $0 == "--image" }.count
    guard imageNames.count == imageFlagCount,
          imageNames.count <= 12, Set(imageNames).count == imageNames.count else {
        throw RunnerError.failed("image inputs are outside the bounded contract")
    }
    for name in imageNames where name.range(of: stagedImageNamePattern,
                                            options: .regularExpression) == nil {
        throw RunnerError.failed("image input name is outside the bounded contract")
    }
    try validateRoots(roots, profile: profile, executable: executable,
                      allowedCwdEntries: Set(imageNames))
    let timeout = Int(value("--timeout-seconds", in: arguments) ?? "90") ?? 0
    guard (1...600).contains(timeout) else { throw RunnerError.failed("timeout is outside the bounded contract") }

    var imagePaths: [String] = []
    var imageBytes: Int64 = 0
    for name in imageNames {
        let path = roots.cwd + "/" + name
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              (st.st_mode & 0o777) == 0o400,
              try canonicalExistingPath(path) == path else {
            throw RunnerError.failed("image input type/mode mismatch")
        }
        imageBytes += Int64(st.st_size)
        guard imageBytes <= 24_000_000 else {
            throw RunnerError.failed("image input bytes exceed the bounded contract")
        }
        imagePaths.append(path)
    }

    let proxy = try AllowlistedConnectProxy()
    defer { proxy.stop() }
    proxy.start()
    let policy = try SandboxPolicy.build(roots: roots, executable: executable, proxyPort: proxy.listener.port)
    try SandboxPolicy.audit(policy, roots: roots, executable: executable, proxyPort: proxy.listener.port)

    let codexArguments = codexExecArguments(
        executable: executable, profile: profile, cwd: roots.cwd, schema: roots.schema,
        imagePaths: imagePaths)
    let spawnArguments = [sandboxExec, "-p", policy] + codexArguments
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let proxyURL = proxy.proxyURL
    let environment = environmentEntries(
        try childEnvironment(roots: roots, home: home, proxyURL: proxyURL))
    try validateExecutableIdentity(expectedIdentity, executable: executable)
    let pid = try spawnProcess(path: sandboxExec, arguments: spawnArguments, environment: environment,
                               currentDirectory: roots.cwd)
    do {
        try validateExecutableIdentity(expectedIdentity, executable: executable)
    } catch {
        _ = waitForProcessGroup(
            pid: pid, timeoutSeconds: 0.01, graceSeconds: 2)
        throw error
    }
    return waitForProcessGroup(
        pid: pid, timeoutSeconds: TimeInterval(timeout), graceSeconds: 2)
}

private func runQuarantine(arguments: [String]) throws {
    let roots = try parseRoots(arguments)
    let executable = try receiptBoundExecutable(arguments)
    let canonicalHome = try canonicalExistingPath(roots.home)
    let root = (canonicalHome as NSString).deletingLastPathComponent
    let systemTemp = try canonicalExistingPath("/private/tmp")
    guard (root as NSString).deletingLastPathComponent == systemTemp,
          (root as NSString).lastPathComponent.hasPrefix(
            "viddydictate-codex-quarantine-"),
          !FileManager.default.fileExists(
            atPath: canonicalHome + "/auth.json") else {
        throw RunnerError.failed("quarantine root is not fresh and unauthenticated")
    }
    for directory in [roots.home, roots.cwd, roots.temp] {
        try requireMode(directory, kind: S_IFDIR, mode: 0o700)
    }
    let expectedIdentity = try expectedExecutableIdentity(arguments)
    try validateExecutableIdentity(expectedIdentity, executable: executable)
    guard let operation = value("--operation", in: arguments) else {
        throw RunnerError.failed("missing quarantine operation")
    }

    var codexArguments: [String]
    switch operation {
    case "version":
        codexArguments = ["--version"]
    case "features":
        codexArguments = ["features", "list"]
    case "seed", "prompt":
        guard let profile = value("--profile", in: arguments) else {
            throw RunnerError.failed("missing quarantine profile")
        }
        try validateRoots(roots, profile: profile, executable: executable)
        codexArguments = [
            "-p", profile, "-C", roots.cwd,
            "debug", "prompt-input", "VIDDYDICTATE_CODEX_C1_BOUNDARY_USER",
        ]
    case "mcp":
        try requireMode(roots.config, kind: S_IFREG, mode: 0o400)
        codexArguments = ["mcp", "list"]
    case "plugins":
        try requireMode(roots.config, kind: S_IFREG, mode: 0o400)
        codexArguments = ["plugin", "list", "--json", "--available"]
    default:
        throw RunnerError.failed("quarantine operation is not allowlisted")
    }

    let policy = try SandboxPolicy.buildQuarantine(
        roots: roots, executable: executable)
    try SandboxPolicy.auditQuarantine(
        policy, roots: roots, executable: executable)
    let environment = try childEnvironment(roots: roots, home: roots.home)
    try validateExecutableIdentity(expectedIdentity, executable: executable)
    let result = try captureBounded(
        executable: sandboxExec,
        arguments: ["-p", policy, executable] + codexArguments,
        environment: environment,
        currentDirectory: roots.cwd,
        timeout: 20,
        limit: 2_097_152,
        postLaunch: {
            try validateExecutableIdentity(expectedIdentity, executable: executable)
        })
    try validateExecutableIdentity(expectedIdentity, executable: executable)
    guard result.status == 0, !result.timedOut, !result.overflow,
          result.stderr.isEmpty else {
        throw RunnerError.failed(
            "quarantine audit command failed or emitted a config warning")
    }
    FileHandle.standardOutput.write(result.stdout)
}

private struct AuthenticatedAuditOutput {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private func authenticatedAuditOutput(
    operation: String,
    result: BoundedCaptureResult
) throws -> AuthenticatedAuditOutput {
    guard !result.timedOut, !result.overflow else {
        throw RunnerError.failed(
            "authenticated metadata audit command failed")
    }
    if operation == "login" {
        return AuthenticatedAuditOutput(
            status: result.status,
            stdout: result.stdout,
            stderr: result.stderr)
    }
    guard result.status == 0, result.stderr.isEmpty else {
        throw RunnerError.failed(
            "authenticated metadata audit command failed")
    }
    return AuthenticatedAuditOutput(
        status: result.status,
        stdout: result.stdout,
        stderr: result.stderr)
}

private func runAuthenticatedAudit(arguments: [String]) throws -> Int32 {
    let roots = try parseRoots(arguments)
    let executable = try receiptBoundExecutable(arguments)
    let expectedIdentity = try expectedExecutableIdentity(arguments)
    try validateExecutableIdentity(expectedIdentity, executable: executable)
    guard let operation = value("--operation", in: arguments) else {
        throw RunnerError.failed("missing authenticated audit operation")
    }
    var codexArguments: [String]
    switch operation {
    case "version":
        codexArguments = ["--version"]
    case "features":
        try requireMode(roots.config, kind: S_IFREG, mode: 0o400)
        codexArguments = ["features", "list"]
    case "mcp":
        try requireMode(roots.config, kind: S_IFREG, mode: 0o400)
        codexArguments = ["mcp", "list"]
    case "plugins":
        try requireMode(roots.config, kind: S_IFREG, mode: 0o400)
        codexArguments = ["plugin", "list", "--json", "--available"]
    case "login":
        try requireMode(roots.config, kind: S_IFREG, mode: 0o400)
        codexArguments = ["login", "status"]
    case "prompt":
        guard let profile = value("--profile", in: arguments) else {
            throw RunnerError.failed("missing authenticated audit profile")
        }
        try validateRoots(
            roots, profile: profile, executable: executable)
        codexArguments = [
            "-p", profile, "-C", roots.cwd,
            "debug", "prompt-input",
            "VIDDYDICTATE_SYNTHETIC_USER_AUDIT_S2",
        ]
    default:
        throw RunnerError.failed("authenticated audit operation is not allowlisted")
    }
    let policy = try SandboxPolicy.buildQuarantine(
        roots: roots, executable: executable)
    try SandboxPolicy.auditQuarantine(
        policy, roots: roots, executable: executable)
    let environment = try childEnvironment(roots: roots, home: roots.home)
    let result = try captureBounded(
        executable: sandboxExec,
        arguments: ["-p", policy, executable] + codexArguments,
        environment: environment,
        currentDirectory: roots.cwd,
        timeout: 20,
        limit: 2_097_152,
        postLaunch: {
            try validateExecutableIdentity(
                expectedIdentity, executable: executable)
        })
    let output = try authenticatedAuditOutput(
        operation: operation,
        result: result)
    FileHandle.standardOutput.write(output.stdout)
    FileHandle.standardError.write(output.stderr)
    return output.status
}

private func spawnProcess(
    path: String,
    arguments: [String],
    environment: [String],
    currentDirectory: String,
    stdinFD: Int32? = nil,
    stdoutFD: Int32? = nil,
    stderrFD: Int32? = nil
) throws -> pid_t {
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    guard posix_spawnattr_init(&attributes) == 0,
          posix_spawn_file_actions_init(&actions) == 0 else {
        throw RunnerError.failed("process-group spawn initialization failed")
    }
    defer { posix_spawnattr_destroy(&attributes); posix_spawn_file_actions_destroy(&actions) }
    let flags = Int16(POSIX_SPAWN_SETPGROUP)
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0,
          posix_spawn_file_actions_addchdir_np(&actions, currentDirectory) == 0 else {
        throw RunnerError.failed("process-group spawn configuration failed")
    }
    for (source, destination) in [
        (stdinFD, STDIN_FILENO),
        (stdoutFD, STDOUT_FILENO),
        (stderrFD, STDERR_FILENO),
    ] {
        if let source,
           posix_spawn_file_actions_adddup2(
            &actions, source, destination) != 0 {
            throw RunnerError.failed("process-group stdio configuration failed")
        }
    }
    var pid: pid_t = 0
    let status = withCStringArray(arguments) { argv in
        withCStringArray(environment) { envp in
            posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        }
    }
    guard status == 0 else { throw RunnerError.failed("contained Codex spawn failed") }
    _ = setpgid(pid, pid)
    return pid
}

private func withCStringArray<R>(_ strings: [String],
                                 _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers where pointer != nil { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}

private func waitForProcessGroup(
    pid: pid_t,
    timeoutSeconds: TimeInterval,
    graceSeconds: TimeInterval
) -> Int32 {
    let deadline = Date().addingTimeInterval(max(0.01, timeoutSeconds))
    var status: Int32 = 0
    var leaderReaped = false
    while Date() < deadline {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            leaderReaped = true
            break
        }
        if result < 0 && errno != EINTR { break }
        usleep(5_000)
    }
    if leaderReaped && processGroupIsEmpty(pid) {
        return decodedExitStatus(status)
    }

    _ = kill(-pid, SIGTERM)
    let boundedGrace = max(0.02, graceSeconds)
    let cleanupDeadline = Date().addingTimeInterval(boundedGrace)
    let termDeadline = Date().addingTimeInterval(boundedGrace / 2)
    while Date() < termDeadline {
        if !leaderReaped {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { leaderReaped = true }
            else if result < 0 && errno != EINTR { break }
        }
        if leaderReaped && processGroupIsEmpty(pid) { return 124 }
        usleep(5_000)
    }
    if !processGroupIsEmpty(pid) { _ = kill(-pid, SIGKILL) }
    while Date() < cleanupDeadline {
        if !leaderReaped {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { leaderReaped = true }
            else if result < 0 && errno != EINTR { break }
        }
        if leaderReaped && processGroupIsEmpty(pid) { return 124 }
        usleep(5_000)
    }
    return leaderReaped && processGroupIsEmpty(pid) ? 124 : 125
}

private func processGroupIsEmpty(_ processID: pid_t) -> Bool {
    errno = 0
    return kill(-processID, 0) != 0 && errno == ESRCH
}

private func decodedExitStatus(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    if signal == 0 { return (status >> 8) & 0xff }
    return 128 + signal
}

private struct CaptureResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func capture(executable: String, arguments: [String]) throws -> CaptureResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CaptureResult(status: process.terminationStatus,
                         stdout: String(decoding: outData, as: UTF8.self),
                         stderr: String(decoding: errData, as: UTF8.self))
}

private struct BoundedCaptureResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
    let overflow: Bool
}

private func captureBounded(
    executable: String,
    arguments: [String],
    environment: [String: String],
    currentDirectory: String,
    timeout: TimeInterval,
    limit: Int,
    postLaunch: (() throws -> Void)? = nil
) throws -> BoundedCaptureResult {
    let out = Pipe(), err = Pipe()
    let devNull = open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard devNull >= 0 else {
        throw RunnerError.failed("bounded capture could not open null stdin")
    }
    defer { close(devNull) }
    let envp = environmentEntries(environment)
    let pid = try spawnProcess(
        path: executable,
        arguments: [executable] + arguments,
        environment: envp,
        currentDirectory: currentDirectory,
        stdinFD: devNull,
        stdoutFD: out.fileHandleForWriting.fileDescriptor,
        stderrFD: err.fileHandleForWriting.fileDescriptor)
    out.fileHandleForWriting.closeFile()
    err.fileHandleForWriting.closeFile()
    do {
        try postLaunch?()
    } catch {
        _ = waitForProcessGroup(
            pid: pid, timeoutSeconds: 0.01, graceSeconds: 2)
        throw error
    }

    let group = DispatchGroup()
    let lock = NSLock()
    var stdout = Data(), stderr = Data()
    var overflow = false
    for (handle, isStdout) in [
        (out.fileHandleForReading, true),
        (err.fileHandleForReading, false),
    ] {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var captured = Data()
            var localOverflow = false
            while true {
                let chunk = handle.readData(ofLength: 65_536)
                if chunk.isEmpty { break }
                if captured.count < limit {
                    let remaining = limit - captured.count
                    captured.append(chunk.prefix(remaining))
                    if chunk.count > remaining { localOverflow = true }
                } else {
                    localOverflow = true
                }
            }
            lock.lock()
            if isStdout { stdout = captured } else { stderr = captured }
            overflow = overflow || localOverflow
            lock.unlock()
            group.leave()
        }
    }

    let status = waitForProcessGroup(
        pid: pid,
        timeoutSeconds: max(0.1, timeout),
        graceSeconds: 2)
    let timedOut = status == 124
    if group.wait(timeout: .now() + 2) == .timedOut {
        out.fileHandleForReading.closeFile()
        err.fileHandleForReading.closeFile()
        throw RunnerError.failed("bounded capture pipes did not close")
    }
    return BoundedCaptureResult(
        status: status,
        stdout: stdout,
        stderr: stderr,
        timedOut: timedOut,
        overflow: overflow)
}

private func runFixture(arguments: [String]) throws {
    guard arguments.count == 7 else { throw RunnerError.failed("fixture arguments invalid") }
    let roots = Roots(home: arguments[1], cwd: arguments[2], temp: arguments[3])
    let outside = arguments[4]
    let allowedPort = UInt16(arguments[5]) ?? 0
    let deniedPort = UInt16(arguments[6]) ?? 0
    let insideRead = FileManager.default.isReadableFile(atPath: roots.home + "/inside-canary.txt")
    let outsideRead = FileManager.default.isReadableFile(atPath: outside)
    let certificateRead = ((try? Data(contentsOf: URL(fileURLWithPath: "/etc/ssl/cert.pem")))?.isEmpty == false)
    var writes: [String: Bool] = [:]
    for (name, path) in [
        ("home_write", roots.home + "/write-canary"),
        ("cwd_write", roots.cwd + "/write-canary"),
        ("temp_write", roots.temp + "/write-canary"),
    ] {
        do { try Data("synthetic".utf8).write(to: URL(fileURLWithPath: path)); writes[name] = true }
        catch { writes[name] = false }
    }
    let allowedConnect = allowedPort > 0 ? connectTCP(host: "127.0.0.1", port: allowedPort) : nil
    let deniedConnect = deniedPort > 0 ? connectTCP(host: "127.0.0.1", port: deniedPort) : nil
    if let fd = allowedConnect { close(fd) }
    if let fd = deniedConnect { close(fd) }
    let result: [String: Any] = [
        "inside_read": insideRead, "outside_read": outsideRead,
        "certificate_read": certificateRead,
        "home_write": writes["home_write"] == true, "cwd_write": writes["cwd_write"] == true,
        "temp_write": writes["temp_write"] == true,
        "allowed_connect": allowedConnect != nil, "denied_connect": deniedConnect != nil,
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

private func runWatchdogFixture(arguments: [String]) throws -> Never {
    guard arguments.count == 2,
          try isAuthorizedSyntheticScratchPath(arguments[1]) else {
        throw RunnerError.failed("watchdog fixture path invalid")
    }
    let executable = try canonicalExistingPath(CommandLine.arguments[0])
    var descendant: pid_t = 0
    let spawnStatus = withCStringArray([executable, "watchdog-leaf"]) { argv in
        withCStringArray(["PATH=/usr/bin:/bin"]) { envp in
            posix_spawn(&descendant, executable, nil, nil, argv, envp)
        }
    }
    guard spawnStatus == 0 else { throw RunnerError.failed("watchdog fixture descendant spawn failed") }
    let bytes = Data("\(descendant)\n".utf8)
    let fd = open(arguments[1], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
        _ = kill(descendant, SIGKILL)
        throw RunnerError.failed("watchdog fixture pid write failed")
    }
    bytes.withUnsafeBytes { raw in
        if let base = raw.baseAddress { _ = Darwin.write(fd, base, raw.count) }
    }
    _ = fsync(fd); close(fd)
    while true { pause() }
}

private func runWatchdogLeaf() -> Never {
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    while true { pause() }
}

private struct QuarantineRootFixture {
    let executable: String
    let identity: ExpectedExecutableIdentity
    let trapSignal: String
}

private let quarantineFreshnessFailure =
    "[codex-containment][FAIL] quarantine root is not fresh and unauthenticated\n"
private let quarantineSyntheticAuditFailure =
    "[codex-containment][FAIL] quarantine audit command failed or emitted a config warning\n"

private func makeQuarantineRootFixture(
    root: String,
    includeAuth: Bool = false
) throws -> QuarantineRootFixture {
    let fm = FileManager.default
    try fm.createDirectory(
        atPath: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    _ = chmod(root, 0o700)
    let roots = Roots(
        home: root + "/codex-home",
        cwd: root + "/codex-cwd",
        temp: root + "/codex-tmp")
    let executableStore = root + "/codex-executables"
    for directory in [roots.home, roots.cwd, roots.temp, executableStore] {
        try fm.createDirectory(
            atPath: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        _ = chmod(directory, 0o700)
    }
    if includeAuth {
        let auth = roots.home + "/auth.json"
        try Data("OPAQUE_SYNTHETIC_AUTH".utf8).write(
            to: URL(fileURLWithPath: auth),
            options: .withoutOverwriting)
        _ = chmod(auth, 0o400)
    }

    let trapSignal = roots.temp + "/quarantine-trap-signal"
    let script = Data("""
        #!/bin/sh
        trap 'printf "%s\\n" "SYNTHETIC_QUARANTINE_SIGNALLED" > "$TMPDIR/quarantine-trap-signal"; exit 97' TERM INT HUP
        printf '%s\\n' 'SYNTHETIC_QUARANTINE_EXECUTED' > "$TMPDIR/quarantine-trap-signal"
        if [ "${1:-}" = "--version" ]; then
          printf '%s\\n' 'codex-cli synthetic-quarantine'
          exit 0
        fi
        exit 64
        """.utf8)
    let hash = SHA256.hash(data: script)
        .map { String(format: "%02x", $0) }
        .joined()
    let executable = executableStore + "/codex-" + hash
    try script.write(
        to: URL(fileURLWithPath: executable),
        options: .withoutOverwriting)
    _ = chmod(executable, 0o500)
    return QuarantineRootFixture(
        executable: executable,
        identity: try measuredExecutableIdentity(executable),
        trapSignal: trapSignal)
}

private func quarantineFixtureArguments(
    fixture: QuarantineRootFixture,
    argumentRoot: String,
    executablePath: String
) -> [String] {
    let argumentRoots = Roots(
        home: argumentRoot + "/codex-home",
        cwd: argumentRoot + "/codex-cwd",
        temp: argumentRoot + "/codex-tmp")
    return [
        "quarantine",
        "--home", argumentRoots.home,
        "--cwd", argumentRoots.cwd,
        "--tmp", argumentRoots.temp,
        "--operation", "version",
        "--binary-path", executablePath,
    ] + identityArguments(fixture.identity)
}

private func runPositiveQuarantineRootFixture(
    runner: String,
    fixture: QuarantineRootFixture,
    argumentRoot: String,
    executablePath: String
) throws {
    let result = try capture(
        executable: runner,
        arguments: quarantineFixtureArguments(
            fixture: fixture,
            argumentRoot: argumentRoot,
            executablePath: executablePath))
    if result.status == 0,
       result.stdout == "codex-cli synthetic-quarantine\n",
       result.stderr.isEmpty,
       (try? String(contentsOfFile: fixture.trapSignal, encoding: .utf8))
            == "SYNTHETIC_QUARANTINE_EXECUTED\n" {
        return
    }
    if result.status == 1,
       result.stdout.isEmpty,
       result.stderr == quarantineSyntheticAuditFailure,
       !FileManager.default.fileExists(atPath: fixture.trapSignal) {
        // A shell-script snapshot cannot pass this runner's exact process-exec/file-read
        // policy. Reaching the later sanitized command failure proves the freshness,
        // modes, receipt identity, operation, and policy guards all admitted the root.
        return
    }
    if result.status == 1, result.stdout.isEmpty,
       result.stderr == quarantineFreshnessFailure {
        throw RunnerError.failed(
            "existing real quarantine root failed with exactly: "
                + "quarantine root is not fresh and unauthenticated")
    }
    if (result.stdout + result.stderr)
        .localizedCaseInsensitiveContains("operation not permitted") {
        return
    }
    throw RunnerError.failed(
        "existing real quarantine root did not reach the synthetic executable guard")
}

private func requireRejectedQuarantineRootFixture(
    runner: String,
    fixture: QuarantineRootFixture,
    argumentRoot: String,
    executablePath: String
) throws {
    let result = try capture(
        executable: runner,
        arguments: quarantineFixtureArguments(
            fixture: fixture,
            argumentRoot: argumentRoot,
            executablePath: executablePath))
    guard result.status == 1,
          result.stdout.isEmpty,
          result.stderr == quarantineFreshnessFailure,
          !FileManager.default.fileExists(atPath: fixture.trapSignal) else {
        throw RunnerError.failed(
            "invalid quarantine root did not fail at the exact freshness guard")
    }
}

private func parseFixture(_ text: String) -> [String: Bool]? {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    var result: [String: Bool] = [:]
    for key in ["inside_read", "outside_read", "certificate_read", "home_write", "cwd_write", "temp_write",
                "allowed_connect", "denied_connect"] {
        guard let value = object[key] as? Bool else { return nil }
        result[key] = value
    }
    return result
}

private func runSelftest(arguments: [String]) throws {
    guard let root = value("--scratch-root", in: arguments),
          try isAuthorizedSyntheticScratchPath(root) else {
        throw RunnerError.failed("selftest requires an authorized synthetic scratch root")
    }
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let roots = Roots(home: root + "/home", cwd: root + "/cwd", temp: root + "/tmp")
    for path in [roots.home, roots.cwd, roots.temp, root + "/outside"] {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = chmod(path, 0o700)
    }
    let inside = roots.home + "/inside-canary.txt"
    let outside = root + "/outside/outside-canary.txt"
    try Data("SYNTHETIC_INSIDE_CANARY".utf8).write(to: URL(fileURLWithPath: inside))
    try Data("SYNTHETIC_OUTSIDE_CANARY".utf8).write(to: URL(fileURLWithPath: outside))

    let token = "synthetic-token"
    let validHeader = Data((
        "CONNECT chatgpt.com:443 HTTP/1.1\r\n" +
        "Proxy-Authorization: \(ConnectPolicy.authorizationValue(token: token))\r\n\r\n"
    ).utf8)
    guard ConnectPolicy.authorizedTarget(header: validHeader, token: token) == "chatgpt.com:443" else {
        throw RunnerError.failed("allowlisted CONNECT parser rejected the transport host")
    }
    for rejected in [
        "CONNECT example.com:443 HTTP/1.1\r\nProxy-Authorization: \(ConnectPolicy.authorizationValue(token: token))\r\n\r\n",
        "GET https://chatgpt.com/ HTTP/1.1\r\nProxy-Authorization: \(ConnectPolicy.authorizationValue(token: token))\r\n\r\n",
        "CONNECT chatgpt.com:443 HTTP/1.1\r\n\r\n",
    ] where ConnectPolicy.authorizedTarget(header: Data(rejected.utf8), token: token) != nil {
        throw RunnerError.failed("CONNECT proxy accepted a disallowed synthetic destination/request")
    }

    let executable = try canonicalExistingPath(CommandLine.arguments[0])
    let placeholder = try SandboxPolicy.build(roots: roots, executable: executable, proxyPort: 43117)
    try SandboxPolicy.audit(placeholder, roots: roots, executable: executable, proxyPort: 43117)
    print("[containment-selftest][PASS] deny-default policy structure and narrow CONNECT target parser")

    let quarantinePolicy = try SandboxPolicy.buildQuarantine(
        roots: roots, executable: executable)
    try SandboxPolicy.auditQuarantine(
        quarantinePolicy, roots: roots, executable: executable)
    guard !quarantinePolicy.contains("(allow network-outbound"),
          !quarantinePolicy.contains("(allow network-inbound") else {
        throw RunnerError.failed("quarantine policy admitted network access")
    }
    print("[containment-selftest][PASS] quarantine policy has no network allowance")

    // The two properties that made every attachment-carrying cloud sticky-skill run die on 2026-08-12.
    // Both were invisible to the existing image fixture, which drives a FAKE runner and therefore never
    // reached either the sterile-cwd rule or the real Codex argv.
    let stagedName = "vd-input-image-01.png"
    guard sterileCwdIsIntact(entries: [], allowed: []),
          sterileCwdIsIntact(entries: [stagedName], allowed: [stagedName]),
          !sterileCwdIsIntact(entries: [stagedName], allowed: []),
          !sterileCwdIsIntact(entries: [stagedName, "notes.txt"], allowed: [stagedName]),
          !sterileCwdIsIntact(entries: ["notes.txt"], allowed: [stagedName]) else {
        throw RunnerError.failed("sterile cwd rule does not admit exactly the staged image inputs")
    }
    guard stagedName.range(of: stagedImageNamePattern, options: .regularExpression) != nil,
          "../escape.png".range(of: stagedImageNamePattern, options: .regularExpression) == nil,
          "vd-input-image-01.txt".range(of: stagedImageNamePattern, options: .regularExpression) == nil else {
        throw RunnerError.failed("staged image name pattern is outside the bounded contract")
    }
    print("[containment-selftest][PASS] sterile cwd admits exactly the argv-named staged image inputs")

    let withImages = codexExecArguments(
        executable: "/synthetic/codex", profile: "route-synthetic", cwd: roots.cwd,
        schema: roots.schema, imagePaths: [roots.cwd + "/" + stagedName])
    let withoutImages = codexExecArguments(
        executable: "/synthetic/codex", profile: "route-synthetic", cwd: roots.cwd,
        schema: roots.schema, imagePaths: [])
    guard let subcommand = withImages.firstIndex(of: "exec"),
          let image = withImages.firstIndex(of: "--image=" + roots.cwd + "/" + stagedName),
          subcommand < image,
          withImages.last == "-",
          !withImages.contains("-i"),
          withoutImages == withImages.filter({ !$0.hasPrefix("--image=") }) else {
        throw RunnerError.failed("staged images do not follow the exec subcommand as single-valued flags")
    }
    print("[containment-selftest][PASS] staged images follow the exec subcommand, one value per flag")

    let identityFixture = root + "/identity-fixture"
    try Data("AAAA".utf8).write(to: URL(fileURLWithPath: identityFixture))
    _ = chmod(identityFixture, 0o500)
    let measured = try measuredExecutableIdentity(identityFixture)
    try validateExecutableIdentity(measured, executable: identityFixture)
    let roundTrip = try expectedExecutableIdentity(
        ["fixture"] + identityArguments(measured))
    guard roundTrip == measured else {
        throw RunnerError.failed("exact executable identity argv did not round-trip")
    }
    try Data("BBBB".utf8).write(
        to: URL(fileURLWithPath: identityFixture), options: .atomic)
    var replacementRejected = false
    do {
        try validateExecutableIdentity(measured, executable: identityFixture)
    } catch {
        replacementRejected = true
    }
    guard replacementRejected else {
        throw RunnerError.failed("same-path executable replacement race was accepted")
    }
    print("[containment-selftest][PASS] exact executable identity rejects replacement races")

    let watchdogPIDFile = root + "/watchdog-descendant.pid"
    let watchdogPID = try spawnProcess(
        path: executable,
        arguments: [executable, "watchdog-fixture", watchdogPIDFile],
        environment: ["PATH=/usr/bin:/bin", "LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8"],
        currentDirectory: root
    )
    let watchdogStatus = waitForProcessGroup(pid: watchdogPID, timeoutSeconds: 1, graceSeconds: 1)
    guard watchdogStatus == 124,
          let pidText = try? String(contentsOfFile: watchdogPIDFile, encoding: .utf8),
          let descendantPID = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw RunnerError.failed("process-group watchdog fixture did not reach timeout")
    }
    var descendantAlive = true
    for _ in 0..<40 {
        if kill(descendantPID, 0) != 0 && errno == ESRCH { descendantAlive = false; break }
        usleep(50_000)
    }
    if descendantAlive { _ = kill(descendantPID, SIGKILL) }
    guard !descendantAlive else { throw RunnerError.failed("process-group watchdog left a descendant alive") }
    print("[containment-selftest][PASS] process-group SIGTERM/grace/SIGKILL/reap left no descendant")

    var unverified: [String] = []
    let quarantineName =
        "viddydictate-codex-quarantine-\(UUID().uuidString)"
    let privateQuarantineRoot = "/private/tmp/" + quarantineName
    let aliasQuarantineRoot = "/tmp/" + quarantineName
    let privateFixture = try makeQuarantineRootFixture(
        root: privateQuarantineRoot)
    defer { try? FileManager.default.removeItem(atPath: privateQuarantineRoot) }
    let aliasExecutablePath = aliasQuarantineRoot
        + "/codex-executables/"
        + URL(fileURLWithPath: privateFixture.executable).lastPathComponent
    let privateRoots = Roots(
        home: privateQuarantineRoot + "/codex-home",
        cwd: privateQuarantineRoot + "/codex-cwd",
        temp: privateQuarantineRoot + "/codex-tmp")
    let aliasRoots = Roots(
        home: aliasQuarantineRoot + "/codex-home",
        cwd: aliasQuarantineRoot + "/codex-cwd",
        temp: aliasQuarantineRoot + "/codex-tmp")
    let receiptExecutable = try receiptBoundExecutable(
        ["fixture", "--binary-path", aliasExecutablePath])
    let canonicalExecutable = try canonicalExistingPath(
        privateFixture.executable)
    guard receiptExecutable == canonicalExecutable else {
        throw RunnerError.failed(
            "receipt-bound executable did not preserve the realpath form")
    }
    let privatePolicy = try SandboxPolicy.build(
        roots: privateRoots,
        executable: receiptExecutable,
        proxyPort: 43117)
    let aliasNetworkPolicy = try SandboxPolicy.build(
        roots: aliasRoots,
        executable: receiptExecutable,
        proxyPort: 43117)
    let privateQuarantinePolicy = try SandboxPolicy.buildQuarantine(
        roots: privateRoots,
        executable: receiptExecutable)
    let aliasPolicy = try SandboxPolicy.buildQuarantine(
        roots: aliasRoots,
        executable: receiptExecutable)
    let privateEnvironment = environmentEntries(
        try childEnvironment(roots: privateRoots, home: privateRoots.home))
    let aliasEnvironment = environmentEntries(
        try childEnvironment(roots: aliasRoots, home: aliasRoots.home))
    let aliasMetadataRules: Set<String> = [
        "(literal \"/tmp\")",
        "(literal \"\(aliasQuarantineRoot)\")",
    ]
    func exactPolicyLineCount(_ line: String, in policy: String) -> Int {
        policy.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces) == line }
            .count
    }
    func policyForm(_ marker: String, in policy: String) -> String? {
        guard let start = policy.range(of: marker)?.lowerBound else { return nil }
        var cursor = start
        var depth = 0
        var started = false
        var quoted = false
        var escaped = false
        while cursor < policy.endIndex {
            let character = policy[cursor]
            if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "(" {
                depth += 1
                started = true
            } else if character == ")" {
                depth -= 1
                if started, depth == 0 {
                    let end = policy.index(after: cursor)
                    return String(policy[start..<end])
                }
            }
            cursor = policy.index(after: cursor)
        }
        return nil
    }
    func dataRuleSignature(_ policy: String) -> [String]? {
        guard let processExec = policyForm("(allow process-exec", in: policy),
              let fileRead = policyForm("(allow file-read*", in: policy),
              let fileWrite = policyForm("(allow file-write*", in: policy) else {
            return nil
        }
        return [processExec, fileRead, fileWrite]
    }
    func containsAliasDataRule(_ signature: [String]) -> Bool {
        let text = signature.joined(separator: "\n")
        return text.contains("(literal \"/tmp\")")
            || text.contains("(subpath \"/tmp\")")
            || text.contains("(literal \"\(aliasQuarantineRoot)")
            || text.contains("(subpath \"\(aliasQuarantineRoot)")
    }
    func removingAliasMetadata(
        _ policy: String,
        rules: Set<String>
    ) -> String {
        policy.split(separator: "\n", omittingEmptySubsequences: false)
            .filter {
                !rules.contains(
                    $0.trimmingCharacters(in: .whitespaces))
            }
            .joined(separator: "\n")
    }
    func policySHA256(_ policy: String) -> String {
        SHA256.hash(data: Data(policy.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
    let canonicalPolicyFixtureRoot =
        "/private/tmp/viddydictate-codex-policy-golden"
    guard !FileManager.default.fileExists(
        atPath: canonicalPolicyFixtureRoot) else {
        throw RunnerError.failed(
            "fixed canonical policy fixture root already exists")
    }
    let canonicalPolicyFixture = try makeQuarantineRootFixture(
        root: canonicalPolicyFixtureRoot)
    defer {
        try? FileManager.default.removeItem(
            atPath: canonicalPolicyFixtureRoot)
    }
    let canonicalPolicyRoots = Roots(
        home: canonicalPolicyFixtureRoot + "/codex-home",
        cwd: canonicalPolicyFixtureRoot + "/codex-cwd",
        temp: canonicalPolicyFixtureRoot + "/codex-tmp")
    let aliasPolicyFixtureRoot =
        "/tmp/viddydictate-codex-policy-golden"
    let aliasPolicyRoots = Roots(
        home: aliasPolicyFixtureRoot + "/codex-home",
        cwd: aliasPolicyFixtureRoot + "/codex-cwd",
        temp: aliasPolicyFixtureRoot + "/codex-tmp")
    let canonicalPolicyExecutable = try canonicalExistingPath(
        canonicalPolicyFixture.executable)
    let canonicalGoldenNetworkPolicy = try SandboxPolicy.build(
        roots: canonicalPolicyRoots,
        executable: canonicalPolicyExecutable,
        proxyPort: 43117)
    let canonicalGoldenQuarantinePolicy =
        try SandboxPolicy.buildQuarantine(
            roots: canonicalPolicyRoots,
            executable: canonicalPolicyExecutable)
    let aliasGoldenNetworkPolicy = try SandboxPolicy.build(
        roots: aliasPolicyRoots,
        executable: canonicalPolicyExecutable,
        proxyPort: 43117)
    let aliasGoldenQuarantinePolicy =
        try SandboxPolicy.buildQuarantine(
            roots: aliasPolicyRoots,
            executable: canonicalPolicyExecutable)
    let canonicalNetworkPolicySHA256 =
        policySHA256(canonicalGoldenNetworkPolicy)
    let canonicalQuarantinePolicySHA256 =
        policySHA256(canonicalGoldenQuarantinePolicy)
    // Regenerate after deliberate policy review with:
    // VIDDYDICTATE_PRINT_CANONICAL_POLICY_GOLDEN=1 ./scripts/verify.sh deterministic
    let expectedCanonicalNetworkPolicySHA256 =
        "4e270fe3ee128e709490267065e4d2b81c76404a93bba49795af6d70396e0cee"
    let expectedCanonicalQuarantinePolicySHA256 =
        "bc8c019351028c7c11da56490df2f5fd9e5474d8dfdcf828c7d78832a6088d75"
    if ProcessInfo.processInfo.environment[
        "VIDDYDICTATE_PRINT_CANONICAL_POLICY_GOLDEN"] == "1" {
        print(
            "[containment-selftest][GOLDEN] network="
                + canonicalNetworkPolicySHA256
                + " quarantine="
                + canonicalQuarantinePolicySHA256)
    }
    guard canonicalNetworkPolicySHA256
            == expectedCanonicalNetworkPolicySHA256,
          canonicalQuarantinePolicySHA256
            == expectedCanonicalQuarantinePolicySHA256 else {
        throw RunnerError.failed(
            "canonical policy golden mismatch: network "
                + canonicalNetworkPolicySHA256
                + ", quarantine "
                + canonicalQuarantinePolicySHA256)
    }
    let goldenAliasMetadataRules: Set<String> = [
        "(literal \"/tmp\")",
        "(literal \"\(aliasPolicyFixtureRoot)\")",
    ]
    guard removingAliasMetadata(
            aliasGoldenNetworkPolicy,
            rules: goldenAliasMetadataRules)
            == canonicalGoldenNetworkPolicy,
          removingAliasMetadata(
            aliasGoldenQuarantinePolicy,
            rules: goldenAliasMetadataRules)
            == canonicalGoldenQuarantinePolicy else {
        throw RunnerError.failed(
            "alias-minus-metadata policy bytes differ from canonical golden")
    }
    guard aliasNetworkPolicy != privatePolicy,
          aliasPolicy != privateQuarantinePolicy,
          aliasMetadataRules.allSatisfy({
              exactPolicyLineCount($0, in: aliasNetworkPolicy) == 1
                && exactPolicyLineCount($0, in: aliasPolicy) == 1
          }),
          aliasMetadataRules.allSatisfy({
              exactPolicyLineCount($0, in: privatePolicy) == 0
                && exactPolicyLineCount($0, in: privateQuarantinePolicy) == 0
          }) else {
        throw RunnerError.failed(
            "alias-spelled policy is missing metadata-only ancestor literals")
    }
    guard let privateNetworkData = dataRuleSignature(privatePolicy),
          let aliasNetworkData = dataRuleSignature(aliasNetworkPolicy),
          let privateQuarantineData = dataRuleSignature(privateQuarantinePolicy),
          let aliasQuarantineData = dataRuleSignature(aliasPolicy),
          aliasNetworkData == privateNetworkData,
          aliasQuarantineData == privateQuarantineData,
          !containsAliasDataRule(aliasNetworkData),
          !containsAliasDataRule(aliasQuarantineData),
          aliasEnvironment == privateEnvironment else {
        throw RunnerError.failed(
            "/tmp spelling changed canonical data rules, non-metadata policy bytes, or environment bytes")
    }
    let processExecRule =
        "(allow process-exec (literal \"\(canonicalExecutable)\"))"
    guard aliasPolicy.contains(processExecRule),
          !aliasPolicy.contains(
            "(allow process-exec (literal \"\(aliasExecutablePath)\"))") else {
        throw RunnerError.failed(
            "receipt-bound process-exec literal did not use the exact realpath form")
    }
    print("[containment-selftest][PASS] canonical-spelled policy bytes are unchanged")
    print("[containment-selftest][PASS] /tmp spelling adds only alias metadata literals while data rules and environment stay canonical")
    print("[containment-selftest][PASS] receipt-bound process-exec literal uses the exact realpath form")
    let canonicalFixtureRoot = try canonicalExistingPath(
        privateQuarantineRoot)
    let canonicalExecutableStore = try canonicalExistingPath(
        privateQuarantineRoot + "/codex-executables")
    guard aliasPolicy.contains(
            "(literal \"\(canonicalFixtureRoot)\")"),
          aliasPolicy.contains(
            "(literal \"\(canonicalExecutableStore)\")"),
          aliasPolicy.contains(
            "(literal \"\(aliasQuarantineRoot)\")") else {
        throw RunnerError.failed(
            "metadata ancestors did not preserve canonical and alias path resolution")
    }
    print("[containment-selftest][PASS] /tmp-spelled metadata ancestors preserve canonical and alias path resolution")
    try runPositiveQuarantineRootFixture(
        runner: executable,
        fixture: privateFixture,
        argumentRoot: privateQuarantineRoot,
        executablePath: aliasExecutablePath)
    print("[containment-selftest][PASS] existing /private quarantine root passed freshness and receipt guards")

    let aliasName =
        "viddydictate-codex-quarantine-\(UUID().uuidString)"
    let aliasPrivateRoot = "/private/tmp/" + aliasName
    let aliasArgumentRoot = "/tmp/" + aliasName
    let aliasFixture = try makeQuarantineRootFixture(root: aliasPrivateRoot)
    defer { try? FileManager.default.removeItem(atPath: aliasPrivateRoot) }
    try runPositiveQuarantineRootFixture(
        runner: executable,
        fixture: aliasFixture,
        argumentRoot: aliasArgumentRoot,
        executablePath: aliasFixture.executable)
    print("[containment-selftest][PASS] existing /tmp-spelled quarantine root passed freshness and receipt guards")

    let outsideRoot = root + "/outside-quarantine-namespace"
    let outsideFixture = try makeQuarantineRootFixture(root: outsideRoot)
    try requireRejectedQuarantineRootFixture(
        runner: executable,
        fixture: outsideFixture,
        argumentRoot: outsideRoot,
        executablePath: outsideFixture.executable)
    print("[containment-selftest][PASS] existing root outside the quarantine namespace rejects before execution")

    let nonQuarantineRoot =
        "/private/tmp/viddydictate-codex-non-quarantine-\(UUID().uuidString)"
    let nonQuarantineFixture = try makeQuarantineRootFixture(
        root: nonQuarantineRoot)
    defer { try? FileManager.default.removeItem(atPath: nonQuarantineRoot) }
    try requireRejectedQuarantineRootFixture(
        runner: executable,
        fixture: nonQuarantineFixture,
        argumentRoot: nonQuarantineRoot,
        executablePath: nonQuarantineFixture.executable)
    print("[containment-selftest][PASS] direct /private/tmp child with a non-quarantine leaf rejects before execution")

    let authName =
        "viddydictate-codex-quarantine-\(UUID().uuidString)"
    let authRoot = "/private/tmp/" + authName
    let authFixture = try makeQuarantineRootFixture(
        root: authRoot,
        includeAuth: true)
    defer { try? FileManager.default.removeItem(atPath: authRoot) }
    try requireRejectedQuarantineRootFixture(
        runner: executable,
        fixture: authFixture,
        argumentRoot: authRoot,
        executablePath: authFixture.executable)
    print("[containment-selftest][PASS] existing quarantine root with auth rejects before execution")

    var allowedListener: TCPListener?, deniedListener: TCPListener?
    do {
        allowedListener = try TCPListener(); deniedListener = try TCPListener()
    } catch {
        unverified.append("outer sandbox denied synthetic loopback listeners")
    }
    let allowedPort = allowedListener?.port ?? 9
    let deniedPort = deniedListener?.port ?? 10

    let fixtureArgs = ["fixture", roots.home, roots.cwd, roots.temp, outside,
                       String(allowedListener == nil ? 0 : allowedPort),
                       String(deniedListener == nil ? 0 : deniedPort)]
    let policy = try SandboxPolicy.build(roots: roots, executable: executable, proxyPort: allowedPort)
    try SandboxPolicy.audit(policy, roots: roots, executable: executable, proxyPort: allowedPort)
    let sandboxed = try capture(executable: sandboxExec,
                                arguments: ["-p", policy, executable] + fixtureArgs)
    if sandboxed.status == 0, let result = parseFixture(sandboxed.stdout) {
        guard result["inside_read"] == true, result["outside_read"] == false,
              result["certificate_read"] == true,
              result["home_write"] == true, result["cwd_write"] == false,
              result["temp_write"] == true else {
            throw RunnerError.failed("filesystem containment canary failed")
        }
        if allowedListener != nil {
            guard result["allowed_connect"] == true, result["denied_connect"] == false else {
                throw RunnerError.failed("network containment canary failed")
            }
        }
        print("[containment-selftest][PASS] sandbox denied outside-root read and disallowed destination")
    } else if (sandboxed.stdout + sandboxed.stderr).localizedCaseInsensitiveContains("operation not permitted") {
        unverified.append("outer sandbox denied nested sandbox_apply")
    } else {
        throw RunnerError.failed("sandbox profile failed to compile/apply")
    }
    allowedListener?.stop(); deniedListener?.stop()

    if unverified.isEmpty {
        print("CONTAINMENT SELFTEST PASS")
    } else {
        for item in unverified { print("[containment-selftest][UNVERIFIED] \(item)") }
        print("CONTAINMENT SELFTEST PASS WITH UNVERIFIED SANDBOX GATES")
    }
}

private func runAuthenticatedLoginStatusSelftest() throws {
    let root =
        "/private/tmp/viddydictate-codex-login-fixture-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
        atPath: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: root) }
    _ = chmod(root, 0o700)

    func makeFakeCodex(name: String, body: String) throws -> String {
        let path = root + "/" + name
        try Data(body.utf8).write(
            to: URL(fileURLWithPath: path),
            options: .withoutOverwriting)
        _ = chmod(path, 0o500)
        return path
    }

    func captureFakeCodex(_ path: String) throws -> BoundedCaptureResult {
        try captureBounded(
            executable: path,
            arguments: ["login", "status"],
            environment: [
                "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
            ],
            currentDirectory: root,
            timeout: 2,
            limit: 4_096)
    }

    let connectedPath = try makeFakeCodex(
        name: "fake-codex-connected",
        body: """
        #!/bin/sh
        printf '%s\\n' 'Logged in using ChatGPT' >&2
        exit 0
        """)
    let connected = try authenticatedAuditOutput(
        operation: "login",
        result: captureFakeCodex(connectedPath))
    guard connected.status == 0,
          connected.stdout.isEmpty,
          String(decoding: connected.stderr, as: UTF8.self)
            == "Logged in using ChatGPT\n" else {
        throw RunnerError.failed(
            "authenticated login stderr passthrough fixture failed")
    }

    let disconnectedPath = try makeFakeCodex(
        name: "fake-codex-disconnected",
        body: """
        #!/bin/sh
        printf '%s\\n' 'Not logged in' >&2
        exit 1
        """)
    let disconnected = try authenticatedAuditOutput(
        operation: "login",
        result: captureFakeCodex(disconnectedPath))
    guard disconnected.status == 1,
          disconnected.stdout.isEmpty,
          String(decoding: disconnected.stderr, as: UTF8.self)
            == "Not logged in\n" else {
        throw RunnerError.failed(
            "authenticated login disconnected passthrough fixture failed")
    }

    let legacyPath = try makeFakeCodex(
        name: "fake-codex-legacy-stdout",
        body: """
        #!/bin/sh
        printf '%s\\n' 'Logged in using ChatGPT'
        exit 0
        """)
    let legacy = try authenticatedAuditOutput(
        operation: "login",
        result: captureFakeCodex(legacyPath))
    guard legacy.status == 0,
          String(decoding: legacy.stdout, as: UTF8.self)
            == "Logged in using ChatGPT\n",
          legacy.stderr.isEmpty else {
        throw RunnerError.failed(
            "authenticated login legacy stdout fixture failed")
    }

    let warningPath = try makeFakeCodex(
        name: "fake-codex-non-login-warning",
        body: """
        #!/bin/sh
        printf '%s\\n' 'SYNTHETIC_CONFIG_WARNING' >&2
        exit 0
        """)
    do {
        _ = try authenticatedAuditOutput(
            operation: "features",
            result: captureFakeCodex(warningPath))
        throw RunnerError.failed(
            "non-login authenticated audit warning was accepted")
    } catch let error as RunnerError {
        guard error.description
                == "authenticated metadata audit command failed" else {
            throw error
        }
    }

    print("[codex-login-fixture][PASS] stderr status and exit code pass through only for login")
}

private func usage() {
    fputs("Usage: CodexContainmentRunner preflight|quarantine|audit|selftest|audit-login-selftest|exec ...\n", stderr)
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { usage(); exit(2) }
    switch command {
    case "preflight": try runPreflight(arguments: arguments); exit(0)
    case "quarantine": try runQuarantine(arguments: arguments); exit(0)
    case "audit": exit(try runAuthenticatedAudit(arguments: arguments))
    case "selftest": try runSelftest(arguments: arguments); exit(0)
    case "audit-login-selftest":
        try runAuthenticatedLoginStatusSelftest()
        exit(0)
    case "fixture": try runFixture(arguments: arguments); exit(0)
    case "watchdog-fixture": try runWatchdogFixture(arguments: arguments)
    case "watchdog-leaf": runWatchdogLeaf()
    case "exec": exit(try runExec(arguments: arguments))
    default: usage(); exit(2)
    }
} catch {
    // Sanitized by design: never include paths, argv, stdin, child stdout, or raw runtime errors.
    fputs("[codex-containment][FAIL] \((error as? RunnerError)?.description ?? "unexpected runner error")\n", stderr)
    exit(1)
}
