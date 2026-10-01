import Foundation

/// G1 (`--ollama-catalog-selftest`): the pure Ollama catalog parser over offline fixtures. No Ollama
/// process, no network, no preferences.
///
/// The fixtures are the REAL response shapes Ollama 0.34.2 returns (captured read-only from the Boxx on
/// 2026-09-30: `/api/tags`, `/api/show` for a gemma4 model, `/api/ps`), with the numbers replaced so every
/// role has a DISTINCT value (the `07c9af4` lesson: a fixture that gives two roles one value cannot tell
/// them apart). Digests are the literal `fixture-digest`, never 64 hex characters: gitleaks'
/// generic-api-key rule flags those, and the parser never reads a digest.
///
/// The gate carries its own negative controls. The catalog contract is run a second time against each of
/// two deliberately broken stand-ins (a name-based vision detector, and a parser that keeps cloud rows),
/// and the gate FAILS unless the specific assertion aimed at each one reports it. A gate that cannot go red
/// against the bug it names is not a gate.
enum OllamaTagsFixtureSelfTest {
    /// The two seams a mutant may replace. Everything else in the contract is the real parser.
    private struct CatalogSubject {
        let parseLocal: (Data) -> [OllamaInstalledModel]?
        let isVision: (OllamaInstalledModel) -> Bool
    }

    // Assertion names the negative controls look up. Named once so a rename cannot silently detach a
    // mutant from the check that is supposed to catch it.
    private static let visionLookalikeCheck =
        "a model NAMED with vision but without the vision capability is NOT vision"
    private static let cloudExcludedCheck =
        "no cloud row (remote_host, remote_model, :cloud, -cloud) reaches the usable local list"

    /// The one model the fixture treats as really installed. Its name is deliberately one no production
    /// literal could ever match, so a parser that hard-codes a known model id finds nothing.
    private static let installedName = "ollama-fixture-actually-installed:latest"

    static func run() -> Bool {
        print("=== Ollama catalog fixture selftest (/api/tags, /api/show, /api/ps) ===")
        let reporter = SelfTestReporter()

        let real = CatalogSubject(
            parseLocal: { OllamaCatalog.parseLocalTags($0) },
            isVision: { $0.isVision })
        print("--- catalog contract (real parser) ---")
        checkCatalogContract(real, reporter)
        checkTagsDetails(reporter)
        checkGeometry(reporter)
        checkResident(reporter)
        checkNegativeControls(reporter)

        print(reporter.passed
            ? "[ollama-catalog-selftest] PASS"
            : "[ollama-catalog-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - Fixtures

    /// `/api/tags` in Ollama 0.34.2's shape (it now carries `capabilities` and, in `details`, the context
    /// and embedding lengths). Rows, in order:
    /// 1. the really installed model: tags say completion/tools/thinking; `/api/show` adds vision;
    /// 2. a text-only model whose NAME says vision (the name-based-detector trap);
    /// 3. a real ollama.com cloud row (remote_host + remote_model + `-cloud`, tiny size);
    /// 4-6. one cloud marker each: `:cloud` suffix only, `-cloud` suffix only, `remote_model` only;
    /// 7. an embedding-only model (Ollama said it cannot chat);
    /// 8. an older-Ollama row with no capabilities and a non-numeric size (kept, size unknown);
    /// 9. a row with only `model`, no `name`;
    /// 10-11. a blank name, and a duplicate of row 1 (both skipped; first occurrence wins).
    private static let tagsFixture = """
    {"models":[
      {"name":"ollama-fixture-actually-installed:latest","model":"ollama-fixture-actually-installed:latest",
       "modified_at":"2026-09-18T14:10:04.129643576-06:00","size":4977171784,"digest":"fixture-digest",
       "details":{"parent_model":"fixture-parent.gguf","format":"gguf","family":"gemma4","families":["gemma4"],
                  "parameter_size":"7.5B","quantization_level":"Q4_K_M","context_length":131072,
                  "embedding_length":2560},
       "capabilities":["completion","tools","thinking"]},
      {"name":"fixture-vision-lookalike:3b","model":"fixture-vision-lookalike:3b",
       "modified_at":"2026-09-17T09:00:00Z","size":2019393189,"digest":"fixture-digest",
       "details":{"format":"gguf","family":"llama","families":["llama"],"parameter_size":"3.2B",
                  "quantization_level":"Q8_0"},
       "capabilities":["completion","tools"]},
      {"name":"gpt-oss:120b-cloud","model":"gpt-oss:120b-cloud","remote_model":"gpt-oss:120b",
       "remote_host":"https://ollama.com:443","modified_at":"2026-09-16T10:00:00Z","size":384,
       "digest":"fixture-digest",
       "details":{"format":"","family":"gptoss","families":["gptoss"],"parameter_size":"116.8B",
                  "quantization_level":"MXFP4"},
       "capabilities":["completion","tools","thinking"]},
      {"name":"fixture-colon:cloud","model":"fixture-colon:cloud","size":391,"digest":"fixture-digest",
       "capabilities":["completion","vision"]},
      {"name":"fixture-dash:20b-cloud","model":"fixture-dash:20b-cloud","size":397,"digest":"fixture-digest",
       "capabilities":["completion"]},
      {"name":"fixture-remote-model-only:latest","model":"fixture-remote-model-only:latest",
       "remote_model":"fixture-upstream:latest","size":401,"digest":"fixture-digest",
       "capabilities":["completion"]},
      {"name":"nomic-embed-text:latest","model":"nomic-embed-text:latest","size":274302450,
       "digest":"fixture-digest",
       "details":{"format":"gguf","family":"nomic-bert","families":["nomic-bert"],"parameter_size":"137M",
                  "quantization_level":"F16"},
       "capabilities":["embedding"]},
      {"name":"fixture-unanswered:8b","model":"fixture-unanswered:8b","size":"unknown",
       "digest":"fixture-digest","details":{"family":"qwen3"}},
      {"model":"fixture-model-key-only:1b","size":815319791,"digest":"fixture-digest"},
      {"name":"   ","model":"   ","size":11},
      {"name":"ollama-fixture-actually-installed:latest","size":13,"capabilities":["embedding"]}
    ]}
    """

    /// `/api/show` for the installed model, in the real gemma4 shape: arch-prefixed `model_info`, sliding
    /// window and shared-KV fields the estimate deliberately ignores, empty tokenizer arrays (Ollama elides
    /// them unless `verbose`), and a bool array that must not be read as numbers. The KV numbers are
    /// fixture values chosen so no two roles share one: blocks 42, heads 8, KV heads 2, key 256, value 192,
    /// and embedding/heads = 320, which differs from key_length so ignoring key_length shows.
    private static let showFixture = """
    {"modelfile":"# Modelfile generated by \\"ollama show\\"\\nFROM fixture-parent.gguf\\n",
     "parameters":"stop                           \\"<turn|>\\"",
     "template":"{{ .Prompt }}",
     "details":{"parent_model":"fixture-parent.gguf","format":"gguf","family":"gemma4","families":["gemma4"],
                "parameter_size":"7.5B","quantization_level":"Q4_K_M"},
     "model_info":{
       "general.architecture":"gemma4",
       "general.parameter_count":7518069290,
       "general.tags":["fixture","any-to-any"],
       "gemma4.attention.head_count":8,
       "gemma4.attention.head_count_kv":2,
       "gemma4.attention.key_length":256,
       "gemma4.attention.key_length_swa":128,
       "gemma4.attention.layer_norm_rms_epsilon":1e-06,
       "gemma4.attention.shared_kv_layers":18,
       "gemma4.attention.sliding_window":512,
       "gemma4.attention.sliding_window_pattern":[true,true,true,true,true,false],
       "gemma4.attention.value_length":192,
       "gemma4.attention.value_length_swa":96,
       "gemma4.block_count":42,
       "gemma4.context_length":131072,
       "gemma4.embedding_length":2560,
       "tokenizer.ggml.add_bos_token":true,
       "tokenizer.ggml.tokens":[]
     },
     "capabilities":["completion","vision","tools","thinking"],
     "modified_at":"2026-09-18T14:10:04.129643576-06:00"}
    """

    /// A hybrid model with a PER-LAYER `head_count_kv` array (a zero means a layer with no KV cache), no
    /// `general.architecture` (the prefix must be inferred from `*.block_count`), and no `key_length`
    /// (it must fall back to embedding_length / head_count = 2048 / 16 = 128).
    private static let hybridShowFixture = """
    {"details":{"family":"fixturehybrid","parameter_size":"1.1B","quantization_level":"Q4_0"},
     "model_info":{
       "general.parameter_count":1100000000,
       "fixturehybrid.block_count":4,
       "fixturehybrid.attention.head_count":16,
       "fixturehybrid.attention.head_count_kv":[4,0,4,2],
       "fixturehybrid.attention.value_length":96,
       "fixturehybrid.embedding_length":2048,
       "fixturehybrid.context_length":32768
     },
     "capabilities":["completion"]}
    """

    /// `/api/ps`: nanosecond fraction with a numeric offset (Go's RFC 3339 form), a `Z` time with no
    /// fraction, and a row without `size_vram`. Every number is distinct.
    private static let psFixture = """
    {"models":[
      {"name":"ollama-fixture-actually-installed:latest","model":"ollama-fixture-actually-installed:latest",
       "size":6123456789,"digest":"fixture-digest",
       "details":{"parent_model":"","format":"gguf","family":"gemma4","families":["gemma4"],
                  "parameter_size":"7.5B","quantization_level":"Q4_K_M"},
       "expires_at":"2026-09-30T14:10:04.129643576-06:00","size_vram":5987654321,"context_length":8192},
      {"name":"fixture-vision-lookalike:3b","model":"fixture-vision-lookalike:3b","size":3141592653,
       "digest":"fixture-digest","expires_at":"2026-09-30T20:15:00Z","context_length":16384}
    ]}
    """

    // MARK: - Catalog contract (the part the mutants are run against)

    private static func checkCatalogContract(_ subject: CatalogSubject, _ reporter: SelfTestReporter) {
        let usable = subject.parseLocal(Data(tagsFixture.utf8))
        let names = usable?.map(\.name)
        func model(_ name: String) -> OllamaInstalledModel? { usable?.first { $0.name == name } }

        reporter.record(
            "/api/tags parses to exactly the non-cloud chat models, in Ollama's order",
            names == [installedName, "fixture-vision-lookalike:3b", "fixture-unanswered:8b",
                      "fixture-model-key-only:1b"],
            names.map { $0.joined(separator: ", ") } ?? "nil")

        let cloudNames: Set<String> = [
            "gpt-oss:120b-cloud", "fixture-colon:cloud", "fixture-dash:20b-cloud",
            "fixture-remote-model-only:latest",
        ]
        reporter.record(
            cloudExcludedCheck,
            usable.map { list in !list.contains { cloudNames.contains($0.name) || $0.isCloud } } == true)

        // The installed model only gains vision through /api/show, so this also proves the merge.
        let installed = model(installedName)
        let merged = installed.map { OllamaCatalog.merging($0, showData: Data(showFixture.utf8)) }
        let lookalike = model("fixture-vision-lookalike:3b")
        reporter.record(
            visionLookalikeCheck,
            lookalike != nil && lookalike.map(subject.isVision) == false)
        reporter.record(
            "a plain-named model whose /api/show capabilities include vision IS vision",
            merged != nil && merged.map(subject.isVision) == true)
        reporter.record(
            "before /api/show is merged, the same plain-named model is not yet vision",
            installed != nil && installed.map(subject.isVision) == false)
        reporter.record(
            "tools and thinking come from capabilities only",
            lookalike?.supportsTools == true && lookalike?.supportsThinking == false
                && merged?.supportsTools == true && merged?.supportsThinking == true)
    }

    // MARK: - /api/tags details the mutants do not touch

    private static func checkTagsDetails(_ reporter: SelfTestReporter) {
        print("--- /api/tags + /api/show details ---")
        let all = OllamaCatalog.parseTags(Data(tagsFixture.utf8))
        func row(_ name: String) -> OllamaInstalledModel? { all?.first { $0.name == name } }

        reporter.record(
            "every cloud marker alone is enough: remote_host, remote_model, :cloud and -cloud",
            row("gpt-oss:120b-cloud")?.isCloud == true
                && row("fixture-colon:cloud")?.isCloud == true
                && row("fixture-dash:20b-cloud")?.isCloud == true
                && row("fixture-remote-model-only:latest")?.isCloud == true
                && row(installedName)?.isCloud == false)
        reporter.record(
            "cloud rows are still parsed (the catalog is honest about what it saw)",
            row("gpt-oss:120b-cloud")?.sizeBytes == 384 && row("gpt-oss:120b-cloud")?.supportsThinking == true)
        let localNames = OllamaCatalog.parseLocalTags(Data(tagsFixture.utf8))?.map(\.name) ?? []
        reporter.record(
            "an embedding-only model is parsed but not offered as a Local chat model",
            row("nomic-embed-text:latest") != nil && !localNames.isEmpty
                && !localNames.contains("nomic-embed-text:latest"))
        reporter.record(
            "size, family, parameter size and quantization are carried per row",
            row(installedName) == OllamaInstalledModel(
                name: installedName, sizeBytes: 4_977_171_784, family: "gemma4", parameterSize: "7.5B",
                quantization: "Q4_K_M", capabilities: ["completion", "tools", "thinking"], isCloud: false)
                && row("fixture-vision-lookalike:3b")?.sizeBytes == 2_019_393_189
                && row("fixture-vision-lookalike:3b")?.quantization == "Q8_0")
        reporter.record(
            "a non-numeric size is unknown (nil) and the row stays usable with unanswered capabilities",
            row("fixture-unanswered:8b")?.sizeBytes == nil
                && row("fixture-unanswered:8b")?.capabilities.isEmpty == true
                && row("fixture-unanswered:8b")?.family == "qwen3")
        reporter.record(
            "a row with only `model` uses it as the name; blank and duplicate names are skipped",
            row("fixture-model-key-only:1b")?.sizeBytes == 815_319_791
                && all?.filter { $0.name == installedName }.count == 1
                && all?.count == 9)
        reporter.record(
            "malformed JSON is unavailable (nil), never an empty authoritative catalog",
            OllamaCatalog.parseTags(Data("{not-json".utf8)) == nil
                && OllamaCatalog.parseTags(Data("[]".utf8)) == nil)
        reporter.record(
            "an empty models list is a real answer: nothing installed",
            OllamaCatalog.parseTags(Data("{\"models\":[]}".utf8)).map { $0.isEmpty } == true)
        reporter.record(
            "/api/show capabilities parse lower-cased; an unparseable show leaves the row unchanged",
            OllamaCatalog.parseShowCapabilities(Data(showFixture.utf8))
                == Set(["completion", "vision", "tools", "thinking"])
                && OllamaCatalog.parseShowCapabilities(Data("{\"capabilities\":[\"Vision\"]}".utf8))
                    == Set(["vision"])
                && row(installedName).map { OllamaCatalog.merging($0, showData: Data("nope".utf8)) }
                    == row(installedName))
    }

    // MARK: - KV geometry

    private static func checkGeometry(_ reporter: SelfTestReporter) {
        print("--- /api/show model_info KV geometry ---")
        let geometry = OllamaCatalog.parseShowGeometry(Data(showFixture.utf8))
        reporter.record(
            "architecture comes from general.architecture and the prefixed keys are read",
            geometry?.architecture == "gemma4" && geometry?.blockCount == 42
                && geometry?.headCountKV == .uniform(2) && geometry?.headCount == .uniform(8)
                && geometry?.keyLength == 256 && geometry?.valueLength == 192
                && geometry?.contextLength == 131_072)

        // Scalar head_count_kv, by hand:
        //   block_count × head_count_kv × (key_length + value_length) × num_ctx × 2 bytes (f16)
        //   = 42 × 2 × (256 + 192) × 8192 × 2
        //   = 84 × 448 × 8192 × 2 = 37,632 × 8192 × 2 = 308,281,344 × 2 = 616,562,688
        // Using head_count (8) instead of head_count_kv, or embedding/heads (320) instead of key_length,
        // or key_length twice, each gives a different number.
        let scalarBytes = geometry?.kvCacheBytes(contextTokens: 8192)
        reporter.record(
            "scalar head_count_kv: KV bytes at num_ctx 8192 = 616,562,688",
            scalarBytes == 616_562_688, scalarBytes.map { "\($0)" } ?? "nil")

        // Per-layer head_count_kv [4, 0, 4, 2], by hand:
        //   Σ heads = 4 + 0 + 4 + 2 = 10; key = 2048 / 16 = 128 (fallback); value = 96
        //   = 10 × (128 + 96) × 4096 × 2 = 10 × 224 × 4096 × 2 = 2,240 × 8192 = 18,350,080
        // Treating the array as max(4) × 4 blocks = 16 heads would give 29,360,128.
        let hybrid = OllamaCatalog.parseShowGeometry(Data(hybridShowFixture.utf8))
        let arrayBytes = hybrid?.kvCacheBytes(contextTokens: 4096)
        reporter.record(
            "architecture is inferred from *.block_count when general.architecture is absent",
            hybrid?.architecture == "fixturehybrid" && hybrid?.headCountKV == .perLayer([4, 0, 4, 2]))
        reporter.record(
            "per-layer head_count_kv array: KV bytes at num_ctx 4096 = 18,350,080 (summed per layer)",
            arrayBytes == 18_350_080, arrayBytes.map { "\($0)" } ?? "nil")

        // A per-layer array SHORTER than block_count is padded with its widest entry, so it over-counts:
        //   blocks 6, array [4, 1] -> 4 + 1 + (6 - 2) × 4 = 21 heads; key 64, value 32
        //   = 21 × 96 × 100 × 2 = 403,200
        let short = OllamaModelGeometry(
            architecture: "fixture", blockCount: 6, headCount: nil, headCountKV: .perLayer([4, 1]),
            keyLength: 64, valueLength: 32, embeddingLength: nil, contextLength: nil)
        reporter.record(
            "a per-layer array shorter than block_count pads with its widest layer (21 heads -> 403,200)",
            short.kvCacheBytes(contextTokens: 100) == 403_200)

        // llama-style GGUF with neither head_count_kv nor key/value lengths:
        //   kv heads = head_count = 4; key = value = 256 / 4 = 64
        //   = 2 blocks × 4 × (64 + 64) × 10 × 2 = 20,480
        let llama = OllamaCatalog.parseShowGeometry(Data("""
        {"model_info":{"general.architecture":"llama","llama.block_count":2,
          "llama.attention.head_count":4,"llama.embedding_length":256}}
        """.utf8))
        reporter.record(
            "no head_count_kv falls back to head_count; no key/value length falls back to embedding/heads",
            llama?.kvCacheBytes(contextTokens: 10) == 20_480)

        let missing = OllamaCatalog.parseShowGeometry(Data("""
        {"model_info":{"general.architecture":"llama","llama.block_count":32}}
        """.utf8))
        reporter.record(
            "missing facts give nil (fall back to the measured table), never a guessed number",
            missing != nil && missing?.kvCacheBytes(contextTokens: 8192) == nil
                && OllamaCatalog.parseShowGeometry(Data("{\"capabilities\":[]}".utf8)) == nil
                && geometry?.kvCacheBytes(contextTokens: 0) == nil)
        reporter.record(
            "a JSON boolean is never read as a count",
            OllamaCatalog.integer(NSNumber(value: true)) == nil && OllamaCatalog.integer(NSNumber(value: 7)) == 7
                && OllamaCatalog.integer(NSNumber(value: 1.5)) == nil)
    }

    // MARK: - /api/ps

    private static func checkResident(_ reporter: SelfTestReporter) {
        print("--- /api/ps resident models ---")
        let resident = OllamaCatalog.parseResident(Data(psFixture.utf8))
        let first = resident?.first
        let second = resident?.dropFirst().first
        // 2026-09-30T14:10:04.129-06:00 = 2026-09-30T20:10:04.129Z = 1,790,799,004.129 s since 1970
        // (nanoseconds truncated to milliseconds). 2026-09-30T20:15:00Z = 1,790,799,300.
        let firstExpiry = Date(timeIntervalSince1970: 1_790_799_004.129)
        let secondExpiry = Date(timeIntervalSince1970: 1_790_799_300)
        func near(_ date: Date?, _ expected: Date) -> Bool {
            guard let date else { return false }
            return abs(date.timeIntervalSince(expected)) < 0.0005
        }
        reporter.record(
            "/api/ps parses name, size, size_vram and context_length per row",
            resident?.count == 2
                && first?.name == installedName && first?.sizeBytes == 6_123_456_789
                && first?.sizeVRAMBytes == 5_987_654_321 && first?.contextLength == 8192
                && second?.name == "fixture-vision-lookalike:3b" && second?.sizeBytes == 3_141_592_653
                && second?.sizeVRAMBytes == nil && second?.contextLength == 16_384)
        reporter.record(
            "expires_at parses with a nanosecond fraction and a numeric offset, and as a plain Z time",
            near(first?.expiresAt, firstExpiry) && near(second?.expiresAt, secondExpiry),
            "\(first?.expiresAt?.timeIntervalSince1970 ?? -1), \(second?.expiresAt?.timeIntervalSince1970 ?? -1)")

        let missingSize = """
        {"models":[
          {"name":"ollama-fixture-actually-installed:latest","size":6123456789,"expires_at":"2026-09-30T20:15:00Z"},
          {"name":"fixture-vision-lookalike:3b","size_vram":1000,"context_length":4096}
        ]}
        """
        let missingName = """
        {"models":[{"size":6123456789},{"name":"fixture-vision-lookalike:3b","size":3141592653}]}
        """
        reporter.record(
            "one row missing size makes the whole list unavailable (fail closed)",
            OllamaCatalog.parseResident(Data(missingSize.utf8)) == nil)
        reporter.record(
            "one row missing a name makes the whole list unavailable (fail closed)",
            OllamaCatalog.parseResident(Data(missingName.utf8)) == nil)
        reporter.record(
            "nothing loaded is an empty list; malformed JSON is nil",
            OllamaCatalog.parseResident(Data("{\"models\":[]}".utf8)).map { $0.isEmpty } == true
                && OllamaCatalog.parseResident(Data("{not-json".utf8)) == nil)
        let badExpiry = OllamaCatalog.parseResident(Data("""
        {"models":[{"name":"fixture-vision-lookalike:3b","size":3141592653,"expires_at":"not-a-date"}]}
        """.utf8))
        reporter.record(
            "an unparseable expires_at is unknown (nil) but does not drop the row",
            badExpiry?.count == 1 && badExpiry?.first?.expiresAt == nil)
    }

    // MARK: - Negative controls

    /// Each mutant replaces one seam of the real parser with the bug it is named for. The contract above
    /// must report that exact bug through the named assertion; if the mutant passes, this gate fails.
    private static func checkNegativeControls(_ reporter: SelfTestReporter) {
        let nameBasedVision = CatalogSubject(
            parseLocal: { OllamaCatalog.parseLocalTags($0) },
            isVision: { model in
                let lowered = model.name.lowercased()
                return lowered.contains("vision") || lowered.contains("-vl")
            })
        requireCaught(reporter, mutant: "name-based vision detector", by: visionLookalikeCheck) {
            checkCatalogContract(nameBasedVision, $0)
        }

        let keepsCloud = CatalogSubject(
            parseLocal: { OllamaCatalog.parseTags($0) },
            isVision: { $0.isVision })
        requireCaught(reporter, mutant: "parser that does not exclude cloud models", by: cloudExcludedCheck) {
            checkCatalogContract(keepsCloud, $0)
        }
    }

    /// Runs `contract` on a throwaway reporter (its lines print as `mutant passes` / `caught`, so the log
    /// never shows a bare FAIL for an expected failure) and records on the real reporter whether the
    /// named assertion caught the mutant.
    private static func requireCaught(_ reporter: SelfTestReporter, mutant: String, by check: String,
                                      _ contract: (SelfTestReporter) -> Void) {
        print("--- negative control: \(mutant) (must be caught) ---")
        let probe = SelfTestReporter(successLabel: "mutant passes", failureLabel: "caught")
        contract(probe)
        let caught = probe.results.contains { $0.name == check && !$0.ok }
        reporter.record("negative control: the \(mutant) is caught by \"\(check)\"", caught)
    }
}
