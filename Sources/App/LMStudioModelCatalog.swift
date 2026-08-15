import Foundation

/// One LM Studio model that can be selected for a Local route. `modelID` is the exact
/// `modelKey` accepted by LM Studio's OpenAI-compatible API; `label` is presentation only.
struct LMStudioModelOption: Equatable {
    let modelID: String
    let label: String

    init(modelID: String, label: String) {
        self.modelID = modelID
        self.label = label
    }
}

/// One installed model row from `lms ls --llm --json`. Vision capability is reported through EITHER of
/// two provider markers, so both are retained and either one is sufficient: a `type` of `vlm`, or a
/// boolean `vision` flag on an ordinary `llm` row. Reading only one of them is what left the Note to
/// Handoff local sanity pass permanently inert (see `smallestVisionModel`).
struct LMStudioInstalledModel: Equatable {
    let modelID: String
    let label: String
    let type: String
    let sizeBytes: Int64?
    /// The provider's `vision` boolean, when it reports one. Null/absent is NOT "no vision" — it is
    /// "this catalog does not answer that question", which is why `type == "vlm"` still counts.
    let visionFlag: Bool?

    /// True when either provider marker says this model can see.
    var isVisionCapable: Bool { type == "vlm" || visionFlag == true }
}

/// Pure parsing and fallback policy for `lms ls --llm --json`.
///
/// Discovery deliberately uses the installed-model catalog rather than `lms ps`, which only
/// describes models currently loaded in memory. The process and availability checks live in
/// `ModelResidency`; keeping the parser pure makes provider drift fixture-testable offline.
enum LMStudioModelCatalog {
    private struct Row: Decodable {
        let type: String?
        let modelKey: String?
        let displayName: String?
        let sizeBytes: Int64?
        let vision: Bool?

        private enum CodingKeys: String, CodingKey {
            case type
            case modelKey
            case displayName
            case sizeBytes
            case vision
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decode(String.self, forKey: .type)
            modelKey = try? container.decode(String.self, forKey: .modelKey)
            displayName = try? container.decode(String.self, forKey: .displayName)
            // Size is optional presentation metadata. Provider drift in this one field must not
            // make an otherwise-selectable model disappear from the Local picker.
            sizeBytes = try? container.decode(Int64.self, forKey: .sizeBytes)
            // Explicitly optional: absent on some catalogs, and JSON `null` on others. Both decode to
            // nil, which means "unanswered", never "no vision".
            vision = try? container.decode(Bool.self, forKey: .vision)
        }
    }

    static func parseInstalled(_ data: Data) -> [LMStudioInstalledModel]? {
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }

        var seen = Set<String>()
        var models: [LMStudioInstalledModel] = []
        for row in rows {
            let type = (row.type ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard type == "llm" || type == "vlm" else { continue }
            let modelID = (row.modelKey ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty, seen.insert(modelID).inserted else { continue }

            let reportedLabel = (row.displayName ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let baseLabel = reportedLabel.isEmpty
                ? ModeModelCatalog.displayName(.local(modelID))
                : reportedLabel
            let label = pickerLabel(baseLabel, sizeBytes: row.sizeBytes)
            let usableSize = row.sizeBytes.flatMap { $0 >= 0 ? $0 : nil }
            models.append(LMStudioInstalledModel(
                modelID: modelID, label: label, type: type, sizeBytes: usableSize,
                visionFlag: row.vision))
        }
        return models
    }

    static func parse(_ data: Data) -> [LMStudioModelOption]? {
        parseInstalled(data)?.compactMap { model in
            guard model.type == "llm" else { return nil }
            return LMStudioModelOption(modelID: model.modelID, label: model.label)
        }
    }

    /// Dynamic local-vision policy for Note to Handoff. Known on-disk sizes sort first; malformed or
    /// missing size metadata remains usable but sorts after every measured VLM. Model id is the stable
    /// tie-breaker, so provider ordering cannot silently change the selected helper.
    ///
    /// Capability is EITHER provider marker (`isVisionCapable`), not one of them. Filtering on
    /// `type == "vlm"` alone shipped a permanently inert local sanity pass: the real
    /// `lms ls --llm --json` on the target machine types every installed model `llm` and answers the
    /// capability question in the boolean `vision` field, so the selector matched nothing and Note to
    /// Handoff silently fell back to filename-only on every single run. A hand-authored fixture cannot
    /// catch that by construction, which is why `LMStudioModelCatalogLiveGate` now asserts it against
    /// the real catalog.
    static func smallestVisionModel(in installed: [LMStudioInstalledModel]?) -> LMStudioInstalledModel? {
        installed?
            .filter(\.isVisionCapable)
            .min {
                let left = $0.sizeBytes ?? Int64.max
                let right = $1.sizeBytes ?? Int64.max
                return left == right ? $0.modelID < $1.modelID : left < right
            }
    }

    /// Matches the decimal units used by `lms ls`. Invalid size metadata is ignored so the label
    /// remains byte-for-byte today's presentation and the row stays selectable.
    private static func pickerLabel(_ label: String, sizeBytes: Int64?) -> String {
        guard let sizeBytes, sizeBytes >= 0 else { return label }

        let bytes = Double(sizeBytes)
        let size: String
        if sizeBytes < 1_000 {
            size = "\(sizeBytes) B"
        } else if sizeBytes < 1_000_000 {
            size = String(format: "%.2f KB", locale: Locale(identifier: "en_US_POSIX"), bytes / 1_000)
        } else if sizeBytes < 1_000_000_000 {
            size = String(format: "%.2f MB", locale: Locale(identifier: "en_US_POSIX"), bytes / 1_000_000)
        } else if sizeBytes < 1_000_000_000_000 {
            size = String(format: "%.2f GB", locale: Locale(identifier: "en_US_POSIX"), bytes / 1_000_000_000)
        } else {
            size = String(format: "%.2f TB", locale: Locale(identifier: "en_US_POSIX"), bytes / 1_000_000_000_000)
        }
        return "\(label) (\(size))"
    }

    /// A missing, malformed, or empty live catalog must never empty or disable the Local picker.
    /// The existing hardcoded catalog remains the deterministic fallback.
    static func pickerOptions(
        discovered: [LMStudioModelOption]?
    ) -> [LMStudioModelOption] {
        guard let discovered, !discovered.isEmpty else {
            return ModeModelCatalog.localModels.map {
                LMStudioModelOption(
                    modelID: $0.modelID,
                    label: ModeModelCatalog.displayName($0))
            }
        }
        return discovered
    }
}
