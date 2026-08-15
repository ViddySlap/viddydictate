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

    init(
        load: @escaping Load = { id, done in
            AudioRetentionStore.shared.loadRecording(id: id, completion: done)
        },
        ensureReady: @escaping EnsureReady = DaemonClient.ensureUp,
        transcribe: @escaping Transcribe = { wav, id, done in
            DaemonClient.transcribe(wav, takeID: id, completion: done)
        },
        schedule: @escaping Schedule = { work in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: work)
        },
        progress: @escaping Progress = { _, _ in }
    ) {
        self.load = load
        self.ensureReady = ensureReady
        self.transcribe = transcribe
        self.schedule = schedule
        self.progress = progress
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
            self.attempt(wav: wav, takeID: takeID, stillCurrent: stillCurrent,
                         completion: completion)
        }
    }

    private func attempt(wav: Data, takeID: UUID,
                         stillCurrent: @escaping () -> Bool,
                         completion: @escaping (RetainedTakeRecoveryResult) -> Void) {
        guard stillCurrent() else { progress(takeID, false); return }
        ensureReady { [weak self] ready in
            guard let self else { return }
            guard stillCurrent() else { self.progress(takeID, false); return }
            guard ready else {
                Log.write("stt.recovery take=\(takeID.uuidString) daemon not ready; retry scheduled")
                self.schedule {
                    self.attempt(wav: wav, takeID: takeID, stillCurrent: stillCurrent,
                                 completion: completion)
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
                Log.write("stt.recovery take=\(takeID.uuidString) retry unavailable "
                    + "error=\(error ?? "none"); retry scheduled")
                self.schedule {
                    self.attempt(wav: wav, takeID: takeID, stillCurrent: stillCurrent,
                                 completion: completion)
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
