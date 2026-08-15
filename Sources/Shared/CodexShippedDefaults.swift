import Foundation

struct CodexShippedModelPair: Hashable, Equatable {
    let model: String
    let effort: String
}

/// Canonical production pair inventory shared by route defaults and the installed-bundle host verifier.
/// It contains no settings access and deliberately deduplicates only exact model/effort pairs.
enum CodexShippedDefaults {
    static let lunaLow = CodexShippedModelPair(model: "gpt-5.6-luna", effort: "low")
    static let legacyCleanupL2Medium =
        CodexShippedModelPair(model: "gpt-5.5", effort: "medium")
    static let solMedium = CodexShippedModelPair(model: "gpt-5.6-sol", effort: "medium")
    static let terraLow = CodexShippedModelPair(model: "gpt-5.6-terra", effort: "low")

    static let distinctPairs: [CodexShippedModelPair] = [
        lunaLow,
        legacyCleanupL2Medium,
        solMedium,
        terraLow,
    ]
}
