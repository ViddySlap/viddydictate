import Foundation

/// The restrictive config must be valid TOML for EVERY feature name upstream lists, and its force-off
/// must land on the feature it names.
///
/// This exists because of a two-week outage. codex-cli 0.154 began listing a dotted feature name,
/// `guardianv2.thread_context`, next to the boolean `guardianv2`. The writer emitted every name as a
/// bare key, so `guardianv2.thread_context = false` became a TOML dotted key that tries to extend a
/// boolean, Codex refused the whole config ("cannot extend value of type boolean with a dotted key"),
/// and every compatibility quarantine failed from 2026-09-15. Nothing offline parsed the generated
/// bytes as TOML, so no gate could see it.
///
/// Offline and synthetic: a fixture inventory, the production `baseConfig` writer, and a scratch
/// directory under TMPDIR. No Codex binary is run.
enum CodexConfigTOMLSelfTest {
    /// Shaped like the real headerless `codex features list`, with the two rows that broke the writer.
    /// The dotted row is `stable` and `true`, as measured on 0.158, so the force-off has real work to do.
    static let dottedInventoryFixture = """
    apps                                 stable             true
    guardianv2                           stable             true
    guardianv2.thread_context            stable             true
    multi_agent                          stable             true
    network_proxy                        experimental       false
    shell_tool                           stable             true
    unified_exec_zsh_fork                under development  false
    use_legacy_landlock                  deprecated         false
    """

    static func run() -> Bool {
        print("=== Codex restrictive config TOML selftest ===")
        let reporter = SelfTestReporter()
        let check = reporter.check
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "viddydictate-codex-config-toml-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try CodexIsolationFoundation.secureDirectory(root)
            let paths = CodexIsolationFoundation.scratchPaths(root: root)
            try CodexIsolationFoundation.prepareDirectories(paths)

            let inventory = try CodexIsolationFoundation.parseFeatureInventory(dottedInventoryFixture)
            check("fixture inventory carries both the boolean and the dotted guardianv2 rows",
                  inventory["guardianv2"]?.enabled == true
                    && inventory["guardianv2.thread_context"]?.enabled == true)

            let config = String(decoding: try CodexIsolationFoundation.baseConfig(
                paths: paths, disabledSkillPaths: [], featureInventory: inventory), as: UTF8.self)

            var parsed: [[String]: CodexConfigTOMLStructure.Value] = [:]
            var parseError = ""
            do { parsed = try CodexConfigTOMLStructure.parse(config) }
            catch { parseError = String(describing: error) }
            reporter.record("generated restrictive config parses as TOML", parseError.isEmpty, parseError)
            check("the boolean guardianv2 is forced false",
                  parsed[["features", "guardianv2"]] == .bool(false))
            check("the dotted guardianv2.thread_context is forced false as ONE quoted key",
                  parsed[["features", "guardianv2.thread_context"]] == .bool(false)
                    && config.contains("\n\"guardianv2.thread_context\" = false\n"))
            check("no feature lands at a nested path the dotted name would have created",
                  parsed.keys.allSatisfy { !($0.first == "features" && $0.count > 2) })
            let forceable = CodexIsolationFoundation.restrictiveFeatureNames(from: inventory)
            check("every forceable feature, and only those, is forced false",
                  Set(parsed.keys.filter { $0.first == "features" }.map { $0[1] }) == Set(forceable)
                    && forceable.allSatisfy { parsed[["features", $0]] == .bool(false) })
            check("bare-safe names keep their historical unquoted bytes",
                  config.contains("\nguardianv2 = false\n") && config.contains("\napps = false\n")
                    && config.contains("\nunified_exec_zsh_fork = false\n"))
            check("TOML key rule: quote exactly the names outside [A-Za-z0-9_-]",
                  CodexIsolationFoundation.tomlKey("shell_tool") == "shell_tool"
                    && CodexIsolationFoundation.tomlKey("a-b_9") == "a-b_9"
                    && CodexIsolationFoundation.tomlKey("guardianv2.thread_context")
                        == "\"guardianv2.thread_context\"")

            // Negative control: the bare-key writer that shipped in 1.1.0. It must be what the checker
            // rejects, or a green above proves nothing.
            let bareLines = CodexIsolationFoundation.restrictiveFeatureLines(
                from: inventory, key: { $0 })
            check("mutant: the 1.1.0 bare writer emits the dotted key unquoted",
                  bareLines.contains("guardianv2.thread_context = false"))
            let mutant = config.replacingOccurrences(
                of: "\n\"guardianv2.thread_context\" = false\n",
                with: "\nguardianv2.thread_context = false\n")
            var mutantError = ""
            do { _ = try CodexConfigTOMLStructure.parse(mutant) }
            catch { mutantError = String(describing: error) }
            reporter.record("mutant: the bare-key config is rejected as invalid TOML",
                            mutant != config && mutantError.contains("cannot extend"), mutantError)

            // The checker itself must also reject the other key-path error, or it is a one-trick fixture.
            var duplicateError = ""
            do { _ = try CodexConfigTOMLStructure.parse("[features]\na = false\na = false\n") }
            catch { duplicateError = String(describing: error) }
            check("checker control: a duplicate key is rejected", duplicateError.contains("duplicate"))
            check("checker control: a quoted dotted key is a single segment",
                  (try? CodexConfigTOMLStructure.parse("[t]\n\"x.y\" = true\nx = false\n"))?[["t", "x.y"]]
                    == .bool(true))
        } catch {
            reporter.record("selftest setup", false, String(describing: error))
        }

        print(reporter.summaryLine(prefix: "[codex-config-toml-selftest]"))
        print(reporter.passed ? "CODEX CONFIG TOML SELFTEST PASS" : "CODEX CONFIG TOML SELFTEST FAIL")
        return reporter.passed
    }
}

/// A strict subset of TOML, test-only: exactly the constructs the restrictive config writer emits
/// (comments, `[table]`, `[[array.of.tables]]`, and `key = value` with basic strings, booleans,
/// integers, and `[]`). Anything outside that subset is an error rather than a guess. Within it, the
/// two key-path rules Codex enforces are enforced here: no key defined twice, and no dotted key that
/// extends a value which is not a table.
enum CodexConfigTOMLStructure {
    enum Value: Equatable {
        case string(String)
        case bool(Bool)
        case integer(Int)
        case emptyArray
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ text: String) throws -> [[String]: Value] {
        var leaves: [[String]: Value] = [:]
        var tables: Set<[String]> = []
        var arrayTables: [[String]: Int] = [:]
        var prefix: [String] = []

        func requireNoLeafAlong(_ path: [String], line: Int) throws {
            guard !path.isEmpty else { return }
            for length in 1...path.count {
                let head = Array(path.prefix(length))
                if let value = leaves[head] {
                    throw Failure(description: "line \(line): cannot extend value of type "
                                    + "\(typeName(value)) with a dotted key")
                }
            }
        }

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[[") {
                guard line.hasSuffix("]]") else { throw Failure(description: "line \(number): bad array table") }
                let path = try parseKey(String(line.dropFirst(2).dropLast(2)), line: number)
                try requireNoLeafAlong(path, line: number)
                guard !tables.contains(path) else {
                    throw Failure(description: "line \(number): duplicate key \(path.joined(separator: "."))")
                }
                let index = arrayTables[path, default: 0]
                arrayTables[path] = index + 1
                prefix = path + ["#\(index)"]
                continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw Failure(description: "line \(number): bad table") }
                let path = try parseKey(String(line.dropFirst().dropLast()), line: number)
                try requireNoLeafAlong(path, line: number)
                guard tables.insert(path).inserted, arrayTables[path] == nil else {
                    throw Failure(description: "line \(number): duplicate key \(path.joined(separator: "."))")
                }
                prefix = path
                continue
            }
            guard let equals = unquotedEquals(in: line) else {
                throw Failure(description: "line \(number): expected key = value")
            }
            let key = try parseKey(String(line[..<equals]), line: number)
            let value = try parseValue(
                String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces),
                line: number)
            let path = prefix + key
            try requireNoLeafAlong(Array(path.dropLast()), line: number)
            guard leaves[path] == nil, !tables.contains(path), arrayTables[path] == nil,
                  !leaves.keys.contains(where: { $0.count > path.count && Array($0.prefix(path.count)) == path })
            else {
                throw Failure(description: "line \(number): duplicate key \(path.joined(separator: "."))")
            }
            leaves[path] = value
        }
        return leaves
    }

    private static func typeName(_ value: Value) -> String {
        switch value {
        case .string: return "string"
        case .bool: return "boolean"
        case .integer: return "integer"
        case .emptyArray: return "array"
        }
    }

    private static func unquotedEquals(in line: String) -> String.Index? {
        var quoted = false
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "=" {
                return index
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// Dotted key: bare segments `[A-Za-z0-9_-]+` or basic strings, joined by `.`.
    private static func parseKey(_ text: String, line: Int) throws -> [String] {
        var segments: [String] = []
        var scalars = Array(text.trimmingCharacters(in: .whitespaces).unicodeScalars)
        guard !scalars.isEmpty else { throw Failure(description: "line \(line): empty key") }
        while true {
            while scalars.first == " " || scalars.first == "\t" { scalars.removeFirst() }
            if scalars.first == "\"" {
                let (value, rest) = try parseBasicString(scalars, line: line)
                segments.append(value)
                scalars = rest
            } else {
                var bare = ""
                while let first = scalars.first, isBareKeyScalar(first) {
                    bare.unicodeScalars.append(first)
                    scalars.removeFirst()
                }
                guard !bare.isEmpty else { throw Failure(description: "line \(line): invalid key") }
                segments.append(bare)
            }
            while scalars.first == " " || scalars.first == "\t" { scalars.removeFirst() }
            if scalars.isEmpty { return segments }
            guard scalars.first == "." else { throw Failure(description: "line \(line): invalid key") }
            scalars.removeFirst()
        }
    }

    private static func isBareKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D: return true
        default: return false
        }
    }

    private static func parseValue(_ text: String, line: Int) throws -> Value {
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if text == "[]" { return .emptyArray }
        if text.hasPrefix("\"") {
            let (value, rest) = try parseBasicString(Array(text.unicodeScalars), line: line)
            guard rest.isEmpty else { throw Failure(description: "line \(line): trailing bytes after string") }
            return .string(value)
        }
        if let integer = Int(text), text.range(of: #"^-?[0-9]+$"#, options: .regularExpression) != nil {
            return .integer(integer)
        }
        throw Failure(description: "line \(line): value outside the supported subset")
    }

    private static func parseBasicString(_ scalars: [Unicode.Scalar], line: Int) throws
        -> (String, [Unicode.Scalar]) {
        guard scalars.first == "\"" else { throw Failure(description: "line \(line): expected string") }
        var result = ""
        var index = 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\"" { return (result, Array(scalars[(index + 1)...])) }
            if scalar == "\\" {
                guard index + 1 < scalars.count else { break }
                let escape = scalars[index + 1]
                switch escape {
                case "b": result += "\u{08}"
                case "t": result += "\t"
                case "n": result += "\n"
                case "f": result += "\u{0C}"
                case "r": result += "\r"
                case "\"": result += "\""
                case "\\": result += "\\"
                case "u":
                    guard index + 5 < scalars.count,
                          let code = UInt32(String(String.UnicodeScalarView(scalars[(index + 2)...(index + 5)])),
                                            radix: 16),
                          let decoded = Unicode.Scalar(code) else {
                        throw Failure(description: "line \(line): bad unicode escape")
                    }
                    result.unicodeScalars.append(decoded)
                    index += 6
                    continue
                default:
                    throw Failure(description: "line \(line): bad escape")
                }
                index += 2
                continue
            }
            guard scalar.value >= 0x20 || scalar == "\t", scalar.value != 0x7F else {
                throw Failure(description: "line \(line): control character in string")
            }
            result.unicodeScalars.append(scalar)
            index += 1
        }
        throw Failure(description: "line \(line): unterminated string")
    }
}
