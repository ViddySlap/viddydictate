import Foundation

/// The transcription daemon's own account of its warm-up, read from the additive `/health` fields
/// `phase`, `phase_s` and `phase_detail` (docs/stt-daemon.md). A daemon older than those fields sends
/// none of them; `phase` is then nil and every consumer falls back to what it did before they existed.
struct DaemonWarmStatus: Equatable {
    enum Phase: String {
        case starting, resolving, downloading, loading, ready, error
    }

    let ready: Bool
    let phase: Phase?
    let phaseSeconds: Double?
    let phaseDetail: String?
    let error: String?
    /// When this answer was read, so a display can keep counting between polls.
    let observedAt: Date

    /// One `/health` body. An unknown phase name parses as nil, the same as an older daemon, rather
    /// than being guessed at.
    static func parse(_ object: [String: Any], observedAt: Date) -> DaemonWarmStatus {
        DaemonWarmStatus(
            ready: (object["ready"] as? Bool) ?? false,
            phase: (object["phase"] as? String).flatMap(Phase.init(rawValue:)),
            phaseSeconds: object["phase_s"] as? Double,
            phaseDetail: object["phase_detail"] as? String,
            error: object["error"] as? String,
            observedAt: observedAt)
    }
}

/// What the HUD says while a take waits on a daemon that is still warming. Pure, so the deterministic
/// rail pins every decision without a daemon, a HUD, or a clock.
///
/// The failure this exists for: a cold start that waited five minutes on the network looked to the
/// user exactly like a broken engine, because the app only retried silently. Any answer from a daemon
/// that reports phases is now said out loud; an older daemon keeps today's wording.
enum DaemonWarmingHUD {
    /// Past this many seconds in one phase the message stops saying "starting" and says what is slow.
    static let slowAfterSeconds: Double = 30
    /// An observation older than this is not shown: the count would be a guess.
    static let staleAfterSeconds: Double = 10
    /// The daemon's `phase_detail` while a first download cannot reach the Hub.
    static let waitingForNetwork = "waiting for the network"
    /// The retained-take toast from before phases existed. Kept verbatim for an older daemon.
    static let legacyRetryToast = "Transcription unavailable. Retrying retained take..."

    /// Seconds in the current phase as of `now`: the daemon's figure plus the time since it was read.
    static func elapsedSeconds(_ status: DaemonWarmStatus, now: Date) -> Double? {
        guard let seconds = status.phaseSeconds else { return nil }
        return max(0, seconds) + max(0, now.timeIntervalSince(status.observedAt))
    }

    /// The HUD line for a waiting take, or nil when there is nothing true to add (an older daemon, a
    /// ready one, or a stale reading).
    static func message(for status: DaemonWarmStatus?, now: Date) -> String? {
        guard let status, let phase = status.phase else { return nil }
        guard now.timeIntervalSince(status.observedAt) <= staleAfterSeconds else { return nil }
        if status.ready || phase == .ready { return nil }
        if phase == .error {
            let reason = (status.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty
                ? "Speech engine failed to start"
                : "Speech engine failed to start: \(bounded(reason))"
        }
        let seconds = Int((elapsedSeconds(status, now: now) ?? 0).rounded(.down))
        guard Double(seconds) >= slowAfterSeconds else {
            return "Speech engine is starting… \(seconds)s"
        }
        if phase == .downloading {
            let why = status.phaseDetail == waitingForNetwork ? waitingForNetwork : "downloading"
            return "Still loading the speech model (\(why))… \(seconds)s"
        }
        return "Still loading the speech model… \(seconds)s"
    }

    /// The toast when a take is queued for a retained retry.
    static func recoveryToast(for status: DaemonWarmStatus?, now: Date) -> String {
        message(for: status, now: now) ?? legacyRetryToast
    }

    /// The parenthetical in Preflight's speech-to-text row while the daemon is not ready, or nil for an
    /// older daemon (which keeps its plain "loading").
    static func preflightDetail(for status: DaemonWarmStatus?) -> String? {
        guard let status, let phase = status.phase, phase != .ready, phase != .error else { return nil }
        let seconds = Int(max(0, status.phaseSeconds ?? 0).rounded(.down))
        if let detail = status.phaseDetail, !detail.isEmpty {
            return "\(phase.rawValue), \(detail), \(seconds)s"
        }
        return "\(phase.rawValue) for \(seconds)s"
    }

    private static func bounded(_ text: String, limit: Int = 80) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
