import AVFoundation
import Foundation

struct WhisperChunk: Sendable {
    let samples: [Float]
    let start: Double
    let isFinal: Bool
}

// Accessed only by AudioFeed's serialized consume/end callbacks.
final class WhisperChunks: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<WhisperChunk, Error>.Continuation
    private var samples: [Float] = []
    // Read by the session only after AudioFeed.finish has joined the audio callback.
    private(set) var submittedSamples = 0
    private(set) var submittedBlocks = 0
    private var start = 0.0
    private var nextCount = 30 * 16_000
    private let overlap = 4 * 16_000

    init(_ continuation: AsyncThrowingStream<WhisperChunk, Error>.Continuation) {
        self.continuation = continuation
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let channel = buffer.floatChannelData?[0] else {
            throw DiktatError(message: "NB-Whisper mottok et ugyldig lydformat.")
        }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        while samples.count >= nextCount {
            try yield(WhisperChunk(samples: Array(samples.prefix(nextCount)), start: start, isFinal: false))
            samples.removeFirst(nextCount - overlap)
            start += Double(nextCount - overlap) / 16_000
            nextCount = 34 * 16_000 // 30 seconds of new audio plus 4 seconds of context.
        }
    }

    private func yield(_ chunk: WhisperChunk) throws {
        if chunk.isFinal, chunk.start > 0, chunk.samples.count == overlap { return }
        var chunk = chunk
        if chunk.isFinal {
            // Whisper tends to drop words that run right up to the end of the
            // audio. A second of trailing silence lets it finish the sentence.
            chunk = WhisperChunk(samples: chunk.samples + [Float](repeating: 0, count: 16_000),
                                 start: chunk.start, isFinal: true)
        }
        submittedSamples += chunk.samples.count
        submittedBlocks += 1
        if case .dropped = continuation.yield(chunk) {
            throw DiktatError(message: "Whisper-køen ble for lang. Opptaket er stoppet; ferdig tekst kan kopieres.")
        }
    }

    func finish(_ error: Error?) {
        if let error { continuation.finish(throwing: error); return }
        do {
            if !samples.isEmpty {
                try yield(WhisperChunk(samples: samples, start: start, isFinal: true))
            }
            samples.removeAll()
            continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }
}

struct WhisperTranscript {
    private var words: [String] = []
    var text: String { words.joined(separator: " ") }

    mutating func append(_ incoming: [WhisperWord], chunk: WhisperChunk) {
        let next = incoming.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
        guard !next.isEmpty else { return }
        var overlap = 0
        // VAD timestamps near pauses are not reliable enough to delete words.
        // Remove only text actually repeated across the overlapping audio.
        if chunk.start > 0 {
            let limit = min(20, words.count, next.count)
            if limit > 0 {
                for count in stride(from: limit, through: 1, by: -1) {
                    let previous = words.suffix(count).map(Self.normalized)
                    let following = next.prefix(count).map(Self.normalized)
                    if previous == following, previous.contains(where: { !$0.isEmpty }) {
                        overlap = count
                        break
                    }
                }
            }
        }
        words.append(contentsOf: next.dropFirst(overlap))
    }

    private static func normalized(_ word: String) -> String {
        word.folding(options: [.caseInsensitive], locale: Locale(identifier: "nb-NO"))
            .filter { $0.isLetter || $0.isNumber }
    }
}

@MainActor
final class WhisperSession: DictationSession {
    var onLevel: ((Float) -> Void)?
    var onText: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?
    private let microphone = Microphone()
    var onInput: ((InputDevice?, Bool) -> Void)? {
        get { microphone.onInput }
        set { microphone.onInput = newValue }
    }
    private let whisper = NBWhisper.shared
    private let model = WhisperModels.shared.availableModel
    private var feed: AudioFeed?
    private var worker: Task<Void, Error>?
    private var cancelled = false
    private var finishing = false
    private var transcript = WhisperTranscript()
    private var blocksFinished = 0
    private var startedAt: Date?
    private var chunks: WhisperChunks?
    private var totalSamples = 0
    private var completedSamples = 0
    private var currentSamples = 0
    private var isFile = false
    private var totalBlocks = 0
    var processingProgress: Double {
        guard totalSamples > 0 else { return 0 }
        let done = Double(completedSamples) + Double(currentSamples) * whisper.progress
        return min(0.99, done / Double(totalSamples))
    }
    var finalizationTimeout: Double {
        // Microphone: bounded queue of at most 8 blocks plus tail/current.
        // File: allow three times real time, and never less than the microphone bound.
        let audioSeconds = Double(totalSamples) / 16_000
        return isFile ? max(180 * 10, audioSeconds * 3) : 180 * 10
    }

    func start(source: AudioSource, locale: String, status: (String) -> Void) async throws {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false) else {
            throw DiktatError(message: "Kunne ikke opprette lydformat.")
        }
        switch source {
        case .microphone:
            try await startMicrophone(output: output, locale: locale, status: status)
        case .file(let url):
            try await startFile(url, output: output, locale: locale, status: status)
        }
    }

    private func startMicrophone(output: AVAudioFormat, locale: String, status: (String) -> Void) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw DiktatError(message: "Mikrofontilgang mangler. Gi Dikta tilgang i Systeminnstillinger.")
        }
        try checkCancellation()
        status("Klargjør mikrofon …")
        let input = try await microphone.open()
        let chunks = makeChunks(bufferingPolicy: .bufferingOldest(8), locale: locale)
        let feed = try AudioFeed(input: input, output: output, level: { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled else { return }
                self.onLevel?(level)
            }
        }, consume: { buffer in
            try chunks.append(buffer)
        }, end: { [weak self] error in
            chunks.finish(error)
            if let error {
                Task { @MainActor [weak self] in
                    guard let self, !self.cancelled else { return }
                    self.onFailure?(error)
                }
            }
        })
        self.feed = feed
        try await microphone.start(tap: feed.makeTap()) { [weak self] error in
            guard let self, !self.cancelled, !self.finishing else { return }
            self.onFailure?(error)
        }
        startedAt = Date()
    }

    // The whole file is decoded up front, so the queue is unbounded and the
    // block count is known before processing starts.
    private func startFile(_ url: URL, output: AVAudioFormat, locale: String, status: (String) -> Void) async throws {
        isFile = true
        status("Leser lydfil …")
        let chunks = makeChunks(bufferingPolicy: .unbounded, locale: locale)
        do {
            try await AudioFileDecoder.decode(url, to: output) { buffer in try chunks.append(buffer) }
        } catch {
            chunks.finish(error)
            throw error
        }
        try checkCancellation()
        chunks.finish(nil)
        guard chunks.submittedSamples > 0 else {
            throw DiktatError(message: "Lydfilen inneholder ingen lyd.")
        }
        totalBlocks = chunks.submittedBlocks
        totalSamples = chunks.submittedSamples
    }

    private func makeChunks(bufferingPolicy: AsyncThrowingStream<WhisperChunk, Error>.Continuation.BufferingPolicy,
                            locale: String) -> WhisperChunks {
        let (stream, continuation) = AsyncThrowingStream<WhisperChunk, Error>.makeStream(bufferingPolicy: bufferingPolicy)
        let chunks = WhisperChunks(continuation)
        self.chunks = chunks
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.whisper.prepare(model: self.model)
                try self.checkCancellation()
                for try await chunk in stream {
                    try self.checkCancellation()
                    self.onStatus?(self.statusText(processing: true))
                    self.currentSamples = chunk.samples.count
                    let words = try await self.whisper.transcribe(chunk.samples, locale: locale)
                    try self.checkCancellation()
                    self.transcript.append(words, chunk: chunk)
                    self.blocksFinished += 1
                    self.completedSamples += chunk.samples.count
                    self.currentSamples = 0
                    self.onText?(self.transcript.text)
                    self.onStatus?(self.statusText(processing: false))
                }
            } catch {
                if !self.cancelled { self.onFailure?(error) }
                throw error
            }
        }
        return chunks
    }

    private func statusText(processing: Bool) -> String {
        if isFile { return "Transkriberer fil · \(blocksFinished) av \(totalBlocks) bolker" }
        if finishing { return "Whisper ferdigstiller · \(blocksFinished) bolker ferdige" }
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let remaining = max(0, Int(duration / 30) - blocksFinished)
        if processing { return "Lytter · Whisper behandler · \(remaining) bolker igjen" }
        return "Lytter · \(blocksFinished) bolker ferdige"
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func stopAudio() {
        microphone.stop()
        feed?.finish()
        feed = nil
    }

    func finish() async throws -> String {
        finishing = true
        // People press stop as the last word leaves their mouth; keep listening a moment.
        if !isFile { try? await Task.sleep(for: .milliseconds(500)) }
        stopAudio()
        totalSamples = chunks?.submittedSamples ?? 0
        onStatus?(statusText(processing: true))
        try await worker?.value
        try checkCancellation()
        worker = nil
        return transcript.text
    }

    func cancel() async {
        cancelled = true
        worker?.cancel()
        stopAudio()
        await whisper.cancel()
        _ = await worker?.result
        worker = nil
        whisper.release()
    }
}
