import Foundation
import CWhisper

// Model files live outside the app bundle and are reused across app updates.
enum NBWhisperAssets {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diktat/Models", isDirectory: true)
    }
    static var vad: URL { directory.appendingPathComponent("silero-v6.2.0.bin") }
    static func validate(_ model: WhisperModel) throws {
        for url in [model.file, vad] {
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw DiktatError(message: "NB-Whisper-modellen mangler. Kjør modellinstallasjonen, eller velg Mac-diktasjon i menyen.")
            }
        }
    }
}

struct WhisperWord: Sendable {
    let text: String
    let start: Double
    let end: Double
}

// All model access is serialized by WhisperWorker. Cancellation alone is
// concurrent, and uses the native atomic flag checked by whisper.cpp.
private final class WhisperHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init() { pointer = diktat_whisper_create()! }
    func cancel() { diktat_whisper_cancel(pointer) }
    deinit { diktat_whisper_free(pointer) }
}

private actor WhisperWorker {
    let handle: WhisperHandle
    init(handle: WhisperHandle) { self.handle = handle }

    private var loadedModel: WhisperModel?
    private(set) var lease = 0

    func prepare(_ model: WhisperModel) throws {
        lease += 1
        if loadedModel == model { return }
        diktat_whisper_unload(handle.pointer)
        loadedModel = nil
        let result = diktat_whisper_load(handle.pointer, model.file.path)
        if result == -2 { throw CancellationError() }
        guard result == 0 else { throw DiktatError(message: "Kunne ikke laste NB-Whisper-modellen.") }
        loadedModel = model
    }

    func transcribe(_ samples: [Float], locale: String) throws -> [WhisperWord] {
        let result = samples.withUnsafeBufferPointer { audio in
            diktat_whisper_run(handle.pointer, audio.baseAddress, Int32(audio.count),
                               locale == "nb-NO" ? "no" : "en", NBWhisperAssets.vad.path)
        }
        if result == -2 { throw CancellationError() }
        guard result == 0 else {
            throw DiktatError(message: "NB-Whisper kunne ikke behandle lydblokken (kode \(result)). Ferdig tekst er bevart.")
        }
        return (0..<diktat_whisper_word_count(handle.pointer)).map { index in
            WhisperWord(text: String(cString: diktat_whisper_word_text(handle.pointer, index)),
                        start: diktat_whisper_word_start(handle.pointer, index),
                        end: diktat_whisper_word_end(handle.pointer, index))
        }
    }

    func waitUntilIdle() {}
    func unload() {
        diktat_whisper_unload(handle.pointer)
        loadedModel = nil
    }

    func unload(unlessPreparedAfter token: Int) -> Bool {
        guard lease == token else { return false }
        unload()
        return true
    }
}

@MainActor
final class NBWhisper: ObservableObject {
    static let shared = NBWhisper()
    // True while the model is being read into memory; recording still works meanwhile.
    @Published private(set) var isLoading = false
    private var loaded: WhisperModel?
    var progress: Double { Double(diktat_whisper_progress(handle.pointer)) / 100 }
    private let handle = WhisperHandle()
    private lazy var worker = WhisperWorker(handle: handle)
    private var unloadTask: Task<Void, Never>?

    func prepare(model: WhisperModel? = nil) async throws {
        unloadTask?.cancel()
        let chosen = model ?? WhisperModels.shared.availableModel
        try NBWhisperAssets.validate(chosen)
        if loaded != chosen { isLoading = true }
        defer { isLoading = false }
        try await worker.prepare(chosen)
        loaded = chosen
        try Task.checkCancellation()
    }

    func transcribe(_ samples: [Float], locale: String) async throws -> [WhisperWord] {
        try Task.checkCancellation()
        diktat_whisper_reset_progress(handle.pointer)
        let result = try await worker.transcribe(samples, locale: locale)
        try Task.checkCancellation()
        return result
    }

    // An idle resident model is paged out to swap over hours, and the next
    // dictation then crawls while it is paged back in. Reloading from disk is
    // quick and overlaps the first 30 seconds of recording.
    func release() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self, worker] in
            let token = await worker.lease
            do { try await Task.sleep(for: .seconds(20 * 60)) } catch { return }
            if await worker.unload(unlessPreparedAfter: token) { self?.loaded = nil }
        }
    }

    func warmUp() async {
        try? await prepare()
        release()
    }

    func shutdown() async {
        handle.cancel()
        await worker.unload()
        loaded = nil
    }

    func cancel() async {
        handle.cancel()
        await worker.waitUntilIdle()
        diktat_whisper_reset_cancel(handle.pointer)
    }
}
