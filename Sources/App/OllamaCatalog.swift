import Foundation

/// One model row from Ollama's `GET /api/tags`, optionally enriched by `POST /api/show`.
///
/// Capability answers come from Ollama's `capabilities` list ONLY, never from the model's name. A tag is
/// whatever the user or a Modelfile called it: `my-vision-notes:latest` can be text-only, and a plain
/// `gemma4:e4b` can see. Guessing from the name is the exact shape of the LM Studio `type == "vlm"` bug
/// (see `LMStudioModelCatalog.smallestVisionModel`), where the selector read the wrong marker and matched
/// nothing in production.
struct OllamaInstalledModel: Equatable {
    /// The tag Ollama's API accepts as `model`, e.g. `gemma4:e4b`.
    let name: String
    /// On-disk size. Nil when Ollama did not report a usable number; it is presentation and a capacity
    /// estimate input, so its absence must not hide the model.
    let sizeBytes: Int64?
    let family: String?
    let parameterSize: String?
    let quantization: String?
    /// Lower-cased capability words (`completion`, `vision`, `tools`, `thinking`, `embedding`). Empty means
    /// "not answered yet", which is the state of an `/api/tags` row from an Ollama that predates
    /// capabilities in the tags listing, before `/api/show` has been merged in.
    let capabilities: Set<String>
    /// A model served by ollama.com rather than this Mac. Parsed so the catalog is honest about what it
    /// saw, but never offered as Local: running it sends the user's text off the machine.
    let isCloud: Bool

    init(name: String, sizeBytes: Int64? = nil, family: String? = nil, parameterSize: String? = nil,
         quantization: String? = nil, capabilities: Set<String> = [], isCloud: Bool = false) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.family = family
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.capabilities = capabilities
        self.isCloud = isCloud
    }

    var isVision: Bool { capabilities.contains(OllamaCatalog.Capability.vision) }
    var supportsTools: Bool { capabilities.contains(OllamaCatalog.Capability.tools) }
    var supportsThinking: Bool { capabilities.contains(OllamaCatalog.Capability.thinking) }

    /// The same row with `/api/show`'s capability answer folded in. A union, not a replacement: both lists
    /// come from the same server about the same model, and a union can only ever add a capability that
    /// Ollama itself reported.
    func mergingCapabilities(_ extra: Set<String>) -> OllamaInstalledModel {
        OllamaInstalledModel(
            name: name, sizeBytes: sizeBytes, family: family, parameterSize: parameterSize,
            quantization: quantization, capabilities: capabilities.union(extra), isCloud: isCloud)
    }
}

/// One loaded model from Ollama's `GET /api/ps`. `sizeBytes` is the whole resident footprint Ollama
/// reports (weights plus the KV cache for the loaded context), which is why it is required and on-disk
/// size is not a substitute for it.
struct OllamaResidentModel: Equatable {
    let name: String
    let sizeBytes: Int64
    /// The part of `sizeBytes` Ollama placed in GPU memory. Kept separately because whether it shows up in
    /// macOS wired memory is a measurement the capacity slice still owes (spec section 4).
    let sizeVRAMBytes: Int64?
    /// The `num_ctx` the model is loaded with. A request that asks for a different one forces a reload.
    let contextLength: Int?
    /// When Ollama will unload it on its own (`keep_alive`). Nil when absent or unparseable.
    let expiresAt: Date?
}

/// The KV-cache facts `/api/show`'s `model_info` carries, kept raw so `kvCacheBytes` can say "unknown"
/// instead of inventing a number. Every field is optional because GGUF metadata varies by architecture:
/// many llama-family files omit `key_length`/`value_length` and some omit `head_count_kv` entirely.
struct OllamaModelGeometry: Equatable {
    /// `head_count_kv` is a scalar on uniform models and a per-layer array on hybrid ones (layers with zero
    /// KV heads carry no cache at all). Both shapes are real, so both are representable.
    enum HeadCount: Equatable {
        case uniform(Int)
        case perLayer([Int])
    }

    let architecture: String
    let blockCount: Int?
    let headCount: HeadCount?
    let headCountKV: HeadCount?
    let keyLength: Int?
    let valueLength: Int?
    let embeddingLength: Int?
    /// The model's trained maximum context. Informational only: the estimate never clamps to it, because
    /// an upper bound that under-counts is worse than one that refuses.
    let contextLength: Int?

    /// A conservative upper bound on the f16 KV cache for `contextTokens`, or nil when the facts needed are
    /// missing (the caller then falls back to the measured table, per spec section 4).
    ///
    /// `Σ(layers) head_count_kv × (key_length + value_length) × contextTokens × 2 bytes`. For a uniform
    /// model the sum is `block_count × head_count_kv`. Sliding-window and shared-KV savings are ignored on
    /// purpose: ADR 0018's guard must err toward refusing a load, never toward an MLX/Metal panic.
    func kvCacheBytes(contextTokens: Int) -> Int64? {
        guard contextTokens > 0, let blocks = blockCount, blocks > 0 else { return nil }
        guard let kvHeadsTotal = totalKVHeads(blocks: blocks), kvHeadsTotal >= 0 else { return nil }
        guard let key = effectiveKeyLength, key > 0 else { return nil }
        let value = valueLength ?? key
        guard value > 0 else { return nil }
        return OllamaModelGeometry.saturatingProduct([
            kvHeadsTotal, Int64(key) + Int64(value), Int64(contextTokens), 2,
        ])
    }

    /// Head count summed over layers. With no `head_count_kv`, GGUF's rule is that it equals `head_count`
    /// (plain multi-head attention), which is also the larger and therefore safer number.
    ///
    /// A per-layer array shorter than `block_count` is padded with its own largest entry, so a truncated
    /// array can only over-count. A longer one is summed whole, for the same reason.
    private func totalKVHeads(blocks: Int) -> Int64? {
        guard let heads = headCountKV ?? headCount else { return nil }
        switch heads {
        case .uniform(let count):
            guard count >= 0 else { return nil }
            return OllamaModelGeometry.saturatingProduct([Int64(blocks), Int64(count)])
        case .perLayer(let counts):
            guard !counts.isEmpty, counts.allSatisfy({ $0 >= 0 }) else { return nil }
            var total = counts.reduce(Int64(0)) { $0 + Int64($1) }
            if counts.count < blocks, let widest = counts.max() {
                total += Int64(blocks - counts.count) * Int64(widest)
            }
            return total
        }
    }

    /// `key_length`, else the classic head dimension `embedding_length / head_count`. With a per-layer
    /// `head_count` the SMALLEST non-zero count is used, which gives the widest head and so the larger
    /// (safer) estimate.
    private var effectiveKeyLength: Int? {
        if let declared = keyLength { return declared }
        guard let embedding = embeddingLength, embedding > 0, let heads = headCount else { return nil }
        let divisor: Int?
        switch heads {
        case .uniform(let count): divisor = count > 0 ? count : nil
        case .perLayer(let counts): divisor = counts.filter { $0 > 0 }.min()
        }
        guard let divisor else { return nil }
        return embedding / divisor
    }

    /// Multiplies without trapping. An overflow means "astronomically large", which for a capacity guard
    /// is a refusal, so it saturates at `Int64.max` rather than wrapping or returning nil.
    private static func saturatingProduct(_ factors: [Int64]) -> Int64 {
        var result: Int64 = 1
        for factor in factors {
            let (product, overflow) = result.multipliedReportingOverflow(by: factor)
            if overflow { return Int64.max }
            result = product
        }
        return result
    }
}

/// Pure parsers for Ollama's native catalog endpoints: `/api/tags`, `/api/show` and `/api/ps`.
///
/// No networking, no `Process`, no `Settings` reads: the HTTP calls belong to the backend slice that
/// wraps these. Keeping the parsing pure is what lets `--ollama-catalog-selftest` pin provider drift on
/// offline fixtures, the way `LMStudioModelCatalog` does for `lms ls`.
enum OllamaCatalog {
    /// Ollama's capability words, as `/api/show` (and, from 0.34, `/api/tags`) reports them.
    enum Capability {
        static let completion = "completion"
        static let vision = "vision"
        static let tools = "tools"
        static let thinking = "thinking"
        static let embedding = "embedding"
    }

    // MARK: - /api/tags

    private struct TagsEnvelope: Decodable {
        let models: [TagsRow]
    }

    private struct TagsDetails: Decodable {
        let family: String?
        let parameterSize: String?
        let quantizationLevel: String?

        private enum CodingKeys: String, CodingKey {
            case family
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            family = try? container.decode(String.self, forKey: .family)
            parameterSize = try? container.decode(String.self, forKey: .parameterSize)
            quantizationLevel = try? container.decode(String.self, forKey: .quantizationLevel)
        }
    }

    private struct TagsRow: Decodable {
        let name: String?
        let model: String?
        let size: Int64?
        let details: TagsDetails?
        let capabilities: [String]?
        let hasRemoteHost: Bool
        let hasRemoteModel: Bool

        private enum CodingKeys: String, CodingKey {
            case name
            case model
            case size
            case details
            case capabilities
            case remoteHost = "remote_host"
            case remoteModel = "remote_model"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Every field is tolerant: drift in one field must not make an otherwise usable model vanish.
            name = try? container.decode(String.self, forKey: .name)
            model = try? container.decode(String.self, forKey: .model)
            size = try? container.decode(Int64.self, forKey: .size)
            details = try? container.decode(TagsDetails.self, forKey: .details)
            capabilities = try? container.decode([String].self, forKey: .capabilities)
            hasRemoteHost = TagsRow.isPresent(container, .remoteHost)
            hasRemoteModel = TagsRow.isPresent(container, .remoteModel)
        }

        /// Present means "the key exists and is not JSON null". The value itself is not needed: any remote
        /// marker at all means the weights are not on this Mac.
        private static func isPresent(_ container: KeyedDecodingContainer<CodingKeys>,
                                      _ key: CodingKeys) -> Bool {
            guard container.contains(key) else { return false }
            return (try? container.decodeNil(forKey: key)) == false
        }
    }

    /// Every row `/api/tags` lists, cloud rows included, in Ollama's order. Rows with no name are skipped,
    /// as are repeats of a name already seen. Nil means the response was not an `/api/tags` body at all,
    /// which callers must treat as "unavailable", never as "no models installed".
    static func parseTags(_ data: Data) -> [OllamaInstalledModel]? {
        guard let envelope = try? JSONDecoder().decode(TagsEnvelope.self, from: data) else { return nil }
        var seen = Set<String>()
        var models: [OllamaInstalledModel] = []
        for row in envelope.models {
            let reported = (row.name ?? row.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reported.isEmpty, seen.insert(reported).inserted else { continue }
            models.append(OllamaInstalledModel(
                name: reported,
                sizeBytes: row.size.flatMap { $0 >= 0 ? $0 : nil },
                family: nonBlank(row.details?.family),
                parameterSize: nonBlank(row.details?.parameterSize),
                quantization: nonBlank(row.details?.quantizationLevel),
                capabilities: normalizedCapabilities(row.capabilities ?? []),
                isCloud: row.hasRemoteHost || row.hasRemoteModel || isCloudName(reported)))
        }
        return models
    }

    /// The models ViddyDictate may offer as Local: never a cloud row, and never a model Ollama has
    /// affirmatively said cannot chat (an embedding-only model). An unanswered capability list is kept,
    /// because an older Ollama that omits capabilities from `/api/tags` still serves chat models.
    static func usableLocalModels(_ all: [OllamaInstalledModel]) -> [OllamaInstalledModel] {
        all.filter { model in
            guard !model.isCloud else { return false }
            if model.capabilities.isEmpty { return true }
            return model.capabilities.contains(Capability.completion)
        }
    }

    /// `/api/tags` straight to the usable Local list. Nil keeps its "unavailable" meaning.
    static func parseLocalTags(_ data: Data) -> [OllamaInstalledModel]? {
        parseTags(data).map { usableLocalModels($0) }
    }

    /// Cloud tags are named `…:cloud` or `…-cloud` (e.g. `gpt-oss:120b-cloud`). Only the suffix counts:
    /// a local model can legitimately have "cloud" elsewhere in its name.
    static func isCloudName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasSuffix(":cloud") || lowered.hasSuffix("-cloud")
    }

    // MARK: - /api/show

    /// The `capabilities` list from an `/api/show` body, lower-cased. Nil when the body is not JSON or does
    /// not carry the list, so a caller can tell "Ollama said nothing" from "Ollama said no capabilities".
    static func parseShowCapabilities(_ data: Data) -> Set<String>? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["capabilities"] as? [Any] else { return nil }
        return normalizedCapabilities(raw.compactMap { $0 as? String })
    }

    /// `model` with `/api/show`'s capabilities folded in. An unparseable show body leaves it unchanged.
    static func merging(_ model: OllamaInstalledModel, showData: Data) -> OllamaInstalledModel {
        guard let extra = parseShowCapabilities(showData) else { return model }
        return model.mergingCapabilities(extra)
    }

    /// The KV geometry in an `/api/show` body's `model_info`. Keys are prefixed by the architecture
    /// (`gemma4.block_count`, `qwen3moe.attention.head_count_kv`, ...). The prefix is
    /// `general.architecture` when present; otherwise it is inferred from the one key ending
    /// `.block_count` (alphabetically first if, oddly, there are several). Nil when there is no
    /// `model_info` or no architecture can be found; missing individual facts stay nil inside the value.
    static func parseShowGeometry(_ data: Data) -> OllamaModelGeometry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = object["model_info"] as? [String: Any] else { return nil }
        let suffix = ".block_count"
        let inferred = info.keys
            .filter { $0.hasSuffix(suffix) && !$0.hasPrefix("general.") }
            .sorted()
            .first
            .map { String($0.dropLast(suffix.count)) }
        let declared = nonBlank(info["general.architecture"] as? String)
        guard let arch = declared ?? inferred else { return nil }

        func int(_ key: String) -> Int? {
            integer(info["\(arch).\(key)"]).flatMap { Int(exactly: $0) }
        }
        func heads(_ key: String) -> OllamaModelGeometry.HeadCount? {
            let raw = info["\(arch).\(key)"]
            if let array = raw as? [Any] {
                var counts: [Int] = []
                for element in array {
                    guard let value = integer(element), let count = Int(exactly: value) else { return nil }
                    counts.append(count)
                }
                return counts.isEmpty ? nil : OllamaModelGeometry.HeadCount.perLayer(counts)
            }
            guard let scalar = integer(raw), let count = Int(exactly: scalar) else { return nil }
            return OllamaModelGeometry.HeadCount.uniform(count)
        }

        return OllamaModelGeometry(
            architecture: arch,
            blockCount: int("block_count"),
            headCount: heads("attention.head_count"),
            headCountKV: heads("attention.head_count_kv"),
            keyLength: int("attention.key_length"),
            valueLength: int("attention.value_length"),
            embeddingLength: int("embedding_length"),
            contextLength: int("context_length"))
    }

    // MARK: - /api/ps

    /// Every loaded model, or nil. Fails CLOSED like `ModelResidency.parseResidentModelsJSON`: one row
    /// without a name or a size makes the whole list unavailable, because the capacity guard must never
    /// mistake a partial resident set for the machine's whole one. An empty `models` array is a real
    /// answer (nothing loaded) and returns `[]`.
    static func parseResident(_ data: Data) -> [OllamaResidentModel]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["models"] as? [Any] else { return nil }
        var resident: [OllamaResidentModel] = []
        for element in rows {
            guard let row = element as? [String: Any],
                  let name = nonBlank((row["name"] as? String) ?? (row["model"] as? String)),
                  let size = integer(row["size"]), size >= 0 else { return nil }
            resident.append(OllamaResidentModel(
                name: name,
                sizeBytes: size,
                sizeVRAMBytes: integer(row["size_vram"]).flatMap { $0 >= 0 ? $0 : nil },
                contextLength: integer(row["context_length"]).flatMap { Int(exactly: $0) },
                expiresAt: (row["expires_at"] as? String).flatMap { parseTimestamp($0) }))
        }
        return resident
    }

    /// Ollama writes Go's RFC 3339 with NANOsecond fractions and a numeric offset
    /// (`2026-09-30T14:10:04.129643576-06:00`). `ISO8601DateFormatter` is only dependable with
    /// millisecond fractions, so the fraction is normalized to exactly three digits first (truncating, so
    /// the parsed instant is never later than the real one). No fraction parses without the option.
    static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let timeMarker = trimmed.firstIndex(of: "T") else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let dot = trimmed[timeMarker...].firstIndex(of: ".") else {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: trimmed)
        }
        let fractionStart = trimmed.index(after: dot)
        var fractionEnd = fractionStart
        while fractionEnd < trimmed.endIndex, trimmed[fractionEnd].isASCII, trimmed[fractionEnd].isNumber {
            fractionEnd = trimmed.index(after: fractionEnd)
        }
        let digits = String(trimmed[fractionStart..<fractionEnd])
        guard !digits.isEmpty else { return nil }
        let millis = String((digits + "000").prefix(3))
        let normalized = String(trimmed[..<fractionStart]) + millis + String(trimmed[fractionEnd...])
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: normalized)
    }

    // MARK: - Helpers

    /// A JSON integer from `JSONSerialization` output. It arrives as `NSNumber`, which also carries JSON
    /// booleans and fractional numbers; both are rejected so `true` can never read as a layer count of 1.
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(.towardZero) else { return nil }
        return number.int64Value
    }

    private static func normalizedCapabilities(_ raw: [String]) -> Set<String> {
        Set(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
