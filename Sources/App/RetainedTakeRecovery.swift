import Foundation

enum RetainedTakeRecoveryResult: Equatable {
    case recovered(String)
    case unavailable(String)
}

/// Retries one failed STT take from the retained WAV after the daemon reports ready.
///
/// The controller keeps the take's original target/state alive while this object works. It loads the WAV
/// once from `AudioRetentionStore`, then retries readiness/transcription without ever re-recording audio.
/// Dependencies are injectable so the deterministic rail can induce the real `model loading` failure shape
/// without touching the user's live daemon or recordings.
final class RetainedTakeRecovery {
    typealias Load = (UUID, @escaping (Data?) -> Void) -> Void
    typealias EnsureReady = (@escaping (Bool) -> Void) -> Void
    typealias Transcribe = (Data, UUID, @escaping (String?, String?) -> Void) -> Void
    typealias Schedule = (@escaping () -> Void) -> Void
    typealias Progress = (UUID, Bool) -> Void

    private let load: Load
    private let ensureReady: EnsureReady
    private let transcribe: Transcribe
    private let schedule: Schedule
    private let progress: Progress
    /// Give-up cap for consecutive transcribe failures against a daemon that reported ready. A
    /// warm-up error (`model loading`) and a not-ready pass never count. The count is scoped to ONE
    /// `recover(...)` call -- threaded through `attempt` as a parameter -- so it starts fresh for
    /// every take and nothing survives a capped finish, a stale/cancelled recovery, or a success.
    /// (A field on this long-lived instance leaked the cap from one take into the next.)
    let maxTranscribeFailures: Int

    init(
        load: @escaping Load = { id, done in
            AudioRetentionStore.shared.loadRecording(id: id, completion: done)
        },
        ensureReady: @escaping EnsureReady = DaemonClient.ensureUp,
        transcribe: @escaping Transcribe = { wav, id, done in
            // vdtpwg4 repair (master ruling item v): `DaemonClient.transcribe` now also hands back the
            // daemon's real decoded segments; this retry path's own `Transcribe` typealias carries no
            // segments (recovery has no segment-threading contract of its own), so they are dropped
            // here, unchanged from today's real behavior.
            DaemonClient.transcribe(wav, takeID: id) { text, error, _ in done(text, error) }
        },
        schedule: @escaping Schedule = { work in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: work)
        },
        progress: @escaping Progress = { _, _ in },
        maxTranscribeFailures: Int = 5
    ) {
        self.load = load
        self.ensureReady = ensureReady
        self.transcribe = transcribe
        self.schedule = schedule
        self.progress = progress
        self.maxTranscribeFailures = maxTranscribeFailures
    }

    func recover(takeID: UUID, retentionWasEnabled: Bool,
                 stillCurrent: @escaping () -> Bool,
                 completion: @escaping (RetainedTakeRecoveryResult) -> Void) {
        progress(takeID, true)
        guard retentionWasEnabled else {
            finish(takeID: takeID, result: .unavailable("audio retention was off"),
                   completion: completion)
            return
        }
        load(takeID) { [weak self] wav in
            guard let self else { return }
            guard stillCurrent() else { self.progress(takeID, false); return }
            guard let wav, !wav.isEmpty else {
                self.finish(takeID: takeID, result: .unavailable("retained clip is unavailable"),
                            completion: completion)
                return
            }
            self.attempt(wav: wav, takeID: takeID, readyFailures: 0,
                         stillCurrent: stillCurrent, completion: completion)
        }
    }

    private func attempt(wav: Data, takeID: UUID, readyFailures: Int,
                         stillCurrent: @escaping () -> Bool,
                         completion: @escaping (RetainedTakeRecoveryResult) -> Void) {
        guard stillCurrent() else { progress(takeID, false); return }
        ensureReady { [weak self] ready in
            guard let self else { return }
            guard stillCurrent() else { self.progress(takeID, false); return }
            guard ready else {
                Log.write("stt.recovery take=\(takeID.uuidString) daemon not ready; retry scheduled")
                self.schedule {
                    self.attempt(wav: wav, takeID: takeID, readyFailures: readyFailures,
                                 stillCurrent: stillCurrent, completion: completion)
                }
                return
            }
            self.transcribe(wav, takeID) { [weak self] text, error in
                guard let self else { return }
                guard stillCurrent() else { self.progress(takeID, false); return }
                if let text {
                    Log.write("stt.recovery take=\(takeID.uuidString) recovered from retained clip")
                    self.finish(takeID: takeID, result: .recovered(text), completion: completion)
                    return
                }
                // Still warming the model: the clip is fine, the engine is not. Retry unlimited and
                // never count it against the give-up cap.
                if (error ?? "").lowercased().contains("model loading") {
                    Log.write("stt.recovery take=\(takeID.uuidString) still warming "
                        + "error=\(error ?? "none"); retry scheduled")
                    self.schedule {
                        self.attempt(wav: wav, takeID: takeID, readyFailures: readyFailures,
                                     stillCurrent: stillCurrent, completion: completion)
                    }
                    return
                }
                // The daemon said it was ready and still could not read this clip. Retrying an
                // unreadable take forever is the endless spinner; give up after a bounded run. The
                // retained WAV is deliberately left on disk for History playback and a manual retry.
                // The count is carried through this attempt chain, never stored, so it belongs to
                // this one recovery and dies with it.
                let newReadyFailures = readyFailures + 1
                if newReadyFailures >= self.maxTranscribeFailures {
                    Log.write("stt.recovery take=\(takeID.uuidString) gave up after "
                        + "\(newReadyFailures) non-warm-up failures; retained clip kept")
                    self.finish(
                        takeID: takeID,
                        result: .unavailable("the speech engine could not read this recording"),
                        completion: completion)
                    return
                }
                Log.write("stt.recovery take=\(takeID.uuidString) retry unavailable "
                    + "error=\(error ?? "none"); retry scheduled")
                self.schedule {
                    self.attempt(wav: wav, takeID: takeID, readyFailures: newReadyFailures,
                                 stillCurrent: stillCurrent, completion: completion)
                }
            }
        }
    }

    private func finish(takeID: UUID, result: RetainedTakeRecoveryResult,
                        completion: @escaping (RetainedTakeRecoveryResult) -> Void) {
        progress(takeID, false)
        completion(result)
    }
}
