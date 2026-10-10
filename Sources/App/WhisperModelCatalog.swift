import Foundation

/// The Whisper model variants ViddyDictate offers as ONE global user choice (selectable Whisper
/// versions, part 1 of 3, backend only). The order is the order a later Settings picker shows, with
/// the default first.
///
/// NOT offered today but verified to exist for a later part: `mlx-community/whisper-medium-mlx`
/// (~1.52 GB) and `mlx-community/whisper-small-mlx` (~0.48 GB). Add them here only with that part.
enum WhisperModelCatalog {
    struct Variant: Equatable {
        /// Stable, UI-independent id (independent of the repo id so the repo can move without
        /// changing a picker's identity).
        let id: String
        /// The exact `mlx-community` Hugging Face repo id the daemon loads.
        let repo: String
        /// Human-facing name.
        let displayName: String
        /// Approximate on-disk size, as measured from the public Hugging Face API on 2026-10-09.
        let approximateSizeBytes: Int64
        /// One neutral line for a later picker. Deliberately no quality/hallucination claims.
        let note: String
    }

    /// Default-first. Sizes are decimal GB as measured on 2026-10-09 (turbo 1.61 GB, the three
    /// non-turbo Large releases 3.08 GB each).
    static let variants: [Variant] = [
        Variant(id: "large-v3-turbo",
                repo: "mlx-community/whisper-large-v3-turbo",
                displayName: "Large V3 Turbo",
                approximateSizeBytes: 1_610_000_000,
                note: "Default. The smallest of the offered models and the fastest to load."),
        Variant(id: "large-v3",
                repo: "mlx-community/whisper-large-v3-mlx",
                displayName: "Large V3",
                approximateSizeBytes: 3_080_000_000,
                note: "About 3.08 GB: a larger download and more memory than Turbo."),
        Variant(id: "large-v2",
                repo: "mlx-community/whisper-large-v2-mlx",
                displayName: "Large V2",
                approximateSizeBytes: 3_080_000_000,
                note: "About 3.08 GB: an earlier Large release, kept for users who prefer it."),
        Variant(id: "large",
                repo: "mlx-community/whisper-large-mlx",
                displayName: "Large (original)",
                approximateSizeBytes: 3_080_000_000,
                note: "About 3.08 GB: the original Large release, kept for users who prefer it."),
    ]

    /// The default variant: Large V3 Turbo, first in the list.
    static var `default`: Variant { variants[0] }

    /// The offered variant for an exact repo id, or nil when the repo is not offered.
    static func variant(forRepo repo: String) -> Variant? {
        variants.first { $0.repo == repo }
    }

    /// True only for a repo id this build offers. Everything else (unknown, stale, hand-edited) is
    /// rejected before it can be persisted or handed to the daemon.
    static func isOffered(repo: String) -> Bool {
        variant(forRepo: repo) != nil
    }
}
