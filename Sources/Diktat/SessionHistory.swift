import Combine
import Foundation

struct HistoryEntry: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case active, done, interrupted, failed, discarded, unfinished
    }

    enum Source: Codable, Hashable {
        case microphone
        case file(String)
        case retranscription(UUID)
    }

    let id: UUID
    let startedAt: Date
    let source: Source
    let engine: String
    let locale: String
    var seconds: Double?
    var microphone: String?
    var text = ""
    var status = Status.active
    var note: String?
    var audio: String?
}

// Every dictation and file transcription, with its text and microphone audio,
// in one folder per session. Text is saved while recording and audio is written
// as it arrives, so a crash leaves the session behind instead of losing it.
@MainActor
final class SessionHistory: ObservableObject {
    static let shared = SessionHistory()
    nonisolated static var directory: URL {
        NBWhisperAssets.directory.deletingLastPathComponent().appendingPathComponent("History", isDirectory: true)
    }
    private nonisolated static let uncompressed = "audio.caf"
    private nonisolated static let compressed = "audio.m4a"
    private nonisolated static let record = "entry.json"

    // Newest first.
    @Published private(set) var entries: [HistoryEntry] = []
    private var archives: [UUID: AudioArchive] = [:]
    private var pendingSaves: Set<UUID> = []
    private var compressing: Set<UUID> = []
    private let disk = DispatchQueue(label: "no.franzvonderlippe.Diktat.history")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    init() { load() }

    func folder(for id: UUID) -> URL {
        Self.directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioURL(for entry: HistoryEntry) -> URL? {
        guard let audio = entry.audio else { return nil }
        let url = folder(for: entry.id).appendingPathComponent(audio)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func begin(_ source: HistoryEntry.Source, engine: String, locale: String, seconds: Double?,
               recordsAudio: Bool) -> (UUID, AudioArchive?) {
        let id = UUID()
        let folder = folder(for: id)
        var archive: AudioArchive?
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if recordsAudio {
                archive = AudioArchive(url: folder.appendingPathComponent(Self.uncompressed))
                archives[id] = archive
            }
        } catch {}
        var entry = HistoryEntry(id: id, startedAt: Date(), source: source, engine: engine, locale: locale)
        entry.seconds = seconds
        if archive != nil { entry.audio = Self.uncompressed }
        entries.insert(entry, at: 0)
        save(entry)
        return (id, archive)
    }

    func update(_ id: UUID, text: String) {
        guard let index = index(of: id), entries[index].text != text else { return }
        entries[index].text = text
        saveSoon(id)
    }

    func update(_ id: UUID, microphone: String) {
        guard let index = index(of: id), entries[index].microphone != microphone else { return }
        entries[index].microphone = microphone
        saveSoon(id)
    }

    // Call once the session's audio has stopped, so the recording is complete.
    func finish(_ id: UUID, text: String, status: HistoryEntry.Status, note: String? = nil) {
        let recorded = archives.removeValue(forKey: id)?.close()
        guard let index = index(of: id) else { return }
        var entry = entries[index]
        entry.text = text
        entry.status = status
        entry.note = note
        if let recorded { entry.seconds = recorded }
        if recorded == 0 { entry.audio = nil }
        // A tap on the hotkey with nothing said is not worth keeping.
        if text.isEmpty && (entry.seconds ?? 0) < 2 {
            delete(id)
            return
        }
        entries[index] = entry
        save(entry)
        if entry.audio == Self.uncompressed { compress(id) }
    }

    // Waits for queued writes, so quitting never drops the latest text.
    func flush() {
        disk.sync {}
    }

    func delete(_ id: UUID) {
        _ = archives.removeValue(forKey: id)?.close()
        entries.removeAll { $0.id == id }
        let folder = folder(for: id)
        disk.async { try? FileManager.default.removeItem(at: folder) }
    }

    private func index(of id: UUID) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    private func save(_ entry: HistoryEntry) {
        let url = folder(for: entry.id).appendingPathComponent(Self.record)
        guard let data = try? encoder.encode(entry) else { return }
        disk.async { try? data.write(to: url, options: .atomic) }
    }

    // Live text changes often; write at most once a second per session.
    private func saveSoon(_ id: UUID) {
        guard pendingSaves.insert(id).inserted else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            pendingSaves.remove(id)
            if let index = index(of: id) { save(entries[index]) }
        }
    }

    private func compress(_ id: UUID) {
        guard compressing.insert(id).inserted else { return }
        let folder = folder(for: id)
        let source = folder.appendingPathComponent(Self.uncompressed)
        let target = folder.appendingPathComponent(Self.compressed)
        Task {
            let seconds = try? await Task.detached(priority: .utility) {
                try AudioArchive.compress(source, to: target)
            }.value
            compressing.remove(id)
            guard let seconds, let index = index(of: id) else { return }
            entries[index].audio = Self.compressed
            if entries[index].seconds == nil { entries[index].seconds = seconds }
            save(entries[index])
            disk.async { try? FileManager.default.removeItem(at: source) }
        }
    }

    // Sessions still marked active on disk were cut short by a crash or quit.
    // Their saved text and recorded audio are kept for a new transcription.
    private func load() {
        Task {
            let stored = await Task.detached(priority: .userInitiated) { Self.read() }.value
            let known = Set(entries.map(\.id))
            var recovered: [HistoryEntry] = []
            for var entry in stored where !known.contains(entry.id) {
                if entry.status == .active {
                    entry.status = .unfinished
                    entry.note = "Dikta ble avsluttet før økten var ferdig."
                    save(entry)
                }
                recovered.append(entry)
            }
            entries = (entries + recovered).sorted { $0.startedAt > $1.startedAt }
            for entry in recovered where entry.audio == Self.uncompressed {
                compress(entry.id)
            }
        }
    }

    private nonisolated static func read() -> [HistoryEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(record)) else { return nil }
            return try? decoder.decode(HistoryEntry.self, from: data)
        }
    }
}
