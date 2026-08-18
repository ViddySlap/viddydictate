import Foundation

/// Local-only rolling retention for the exact post-trim WAV payload sent to the STT daemon.
///
/// Files live beside the full-history directory:
///
///     ~/Library/Application Support/ViddyDictate/recordings/<take UUID>.wav
///
/// The store is deliberately independent of `audioWorkQueue` and URLSession. `retain` performs only
/// the enabled check plus one dispatch on the caller; all filesystem work, including the 100-take
/// eviction pass, runs on this private serial queue while transcription proceeds concurrently.
final class AudioRetentionStore {
    static let shared = AudioRetentionStore()
    static let didChange = Notification.Name("VDAudioRetentionDidChange")
    static let maxTakes = 100

    static func defaultDirectory() -> URL {
        AppPaths.applicationSupportDirectory()
            .appendingPathComponent("recordings", isDirectory: true)
    }

    private let directory: URL
    private let isEnabled: () -> Bool
    private let fm: FileManager
    private let queue = DispatchQueue(label: AppIdentity.queueLabel("audio-retention"),
                                      qos: .utility)

    init(directory: URL = AudioRetentionStore.defaultDirectory(),
         enabled: @escaping () -> Bool = { Settings.retainDictationAudio },
         fileManager: FileManager = .default) {
        self.directory = directory
        self.isEnabled = enabled
        self.fm = fileManager
    }

    /// Enqueue one final take. Partial-preview snapshots pass no take id at their call site and never
    /// reach this method. `at` is injectable so the scratch selftest can prove oldest-first eviction.
    func retain(_ wav: Data, id: UUID, at date: Date = Date(), enabled: Bool? = nil) {
        guard enabled ?? isEnabled(), !wav.isEmpty else { return }
        queue.async {
            let url = self.url(for: id)
            do {
                try self.fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
                try wav.write(to: url, options: .atomic)
                try self.fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
                try self.evictOverflowLocked()
                self.postChange()
            } catch {
                UserDataWriteFailureCenter.report(
                    subsystem: "dictation audio retention", operation: "retain WAV", url: url,
                    error: error)
            }
        }
    }

    /// Read a retained take back through the store's serial queue, then deliver the result off that queue.
    /// Recovery deliberately uses these on-disk bytes rather than the recorder's old in-memory snapshot:
    /// the retained clip is the durable source of truth. The ordering guarantee comes from enqueueing the
    /// read on the serial queue, so a just-enqueued retain finishes before the read begins; the completion
    /// hop does not participate in that ordering, and no caller-supplied code runs while the queue is held.
    func loadRecording(id: UUID, completion: @escaping (Data?) -> Void) {
        queue.async {
            let data = try? Data(contentsOf: self.url(for: id))
            DispatchQueue.global(qos: .utility).async {
                completion(data)
            }
        }
    }

    /// Return the retained file for a History row, if it still exists. Queue synchronization makes a
    /// simultaneous purge/eviction a clean before-or-after observation rather than a filesystem race.
    func recordingURL(for id: UUID) -> URL? {
        queue.sync {
            let candidate = url(for: id)
            return fm.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }

    /// Delete every retained WAV without touching transcription history. The directory is removed too;
    /// the next enabled take recreates it. This is the Settings purge-control seam.
    func purge() {
        queue.async {
            do {
                if self.fm.fileExists(atPath: self.directory.path) {
                    try self.fm.removeItem(at: self.directory)
                }
                self.postChange()
            } catch {
                UserDataWriteFailureCenter.report(
                    subsystem: "dictation audio retention", operation: "purge recordings",
                    url: self.directory, error: error)
            }
        }
    }

    /// Scratch-test barriers/introspection. Production never blocks on retention.
    func flush() { queue.sync {} }
    func retainedIDs() -> [UUID] {
        queue.sync { retainedFilesLocked().compactMap { UUID(uuidString: $0.url.deletingPathExtension().lastPathComponent) } }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: false)
            .appendingPathExtension("wav")
    }

    private struct RetainedFile {
        let url: URL
        let modified: Date
    }

    /// Same locked purge shape as sticky-note history: enumerate the owned directory, order by the
    /// retention clock with a stable filename tie-break, then remove the oldest overflow.
    private func evictOverflowLocked() throws {
        let files = retainedFilesLocked().sorted {
            if $0.modified != $1.modified { return $0.modified < $1.modified }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        let overflow = files.count - Self.maxTakes
        guard overflow > 0 else { return }
        for file in files.prefix(overflow) { try fm.removeItem(at: file.url) }
    }

    private func retainedFilesLocked() -> [RetainedFile] {
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "wav",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { return nil }
            return RetainedFile(url: url, modified: values.contentModificationDate ?? .distantPast)
        }
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }
}
