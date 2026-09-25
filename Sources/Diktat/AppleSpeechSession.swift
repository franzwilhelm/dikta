import AVFoundation
import Speech
import Foundation

@MainActor
final class AppleSpeechSession: DictationSession {
    private let microphone = Microphone()
    var onInput: ((InputDevice?, Bool) -> Void)? {
        get { microphone.onInput }
        set { microphone.onInput = newValue }
    }
    private var analyzer: SpeechAnalyzer?
    private var feed: AudioFeed?
    private var resultsTask: Task<Void, Error>?
    private var cancelled = false
    private var buffer = TranscriptBuffer()
    var onLevel: ((Float) -> Void)?
    var onText: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?
    var processingProgress: Double { 0 } // Apple exposes no finalization progress.
    private var fileSeconds = 0.0
    var finalizationTimeout: Double { max(30, fileSeconds * 2) }

    func start(source: AudioSource, locale identifier: String, status: (String) -> Void) async throws {
        if !source.isFile {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw DiktatError(message: "Mikrofontilgang mangler. Åpne Systeminnstillinger → Personvern og sikkerhet → Mikrofon.")
            }
        }
        try checkCancellation()
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw DiktatError(message: "Dette språket støttes ikke av Apples lokale diktasjon.")
        }
        try checkCancellation()
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        try await AssetInventory.reserve(locale: locale)
        try checkCancellation()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status("Laster ned språkmodell …")
            try await request.downloadAndInstall()
        }
        try checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, !self.cancelled else { return }
                    self.buffer.update(result)
                    self.onText?(self.buffer.text)
                }
            } catch {
                if let self, !self.cancelled { self.onFailure?(error) }
                throw error
            }
        }
        switch source {
        case .microphone:
            try await startMicrophone(analyzer: analyzer, transcriber: transcriber, status: status)
        case .file(let url):
            try await startFile(url, analyzer: analyzer, transcriber: transcriber, status: status)
        }
    }

    private func startMicrophone(analyzer: SpeechAnalyzer, transcriber: DictationTranscriber,
                                 status: (String) -> Void) async throws {
        status("Klargjør mikrofon …")
        let input = try await microphone.open()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: input) else {
            throw DiktatError(message: "Fant ikke et støttet lydformat.")
        }
        try await analyzer.prepareToAnalyze(in: format)
        try checkCancellation()
        let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let feed = try AudioFeed(input: input, output: format, level: { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled else { return }
                self.onLevel?(level)
            }
        }, consume: { buffer in
            if case .dropped = continuation.yield(AnalyzerInput(buffer: buffer)) {
                throw DiktatError(message: "Talegjenkjenningen klarte ikke å holde følge.")
            }
        }, end: { error in
            continuation.finish(throwing: error)
        })
        self.feed = feed
        try await analyzer.start(inputSequence: stream)
        try checkCancellation()
        try await microphone.start(tap: feed.makeTap()) { [weak self] error in
            guard let self, !self.cancelled else { return }
            self.onFailure?(error)
        }
    }

    // The whole file is decoded into the analyzer's format and queued before finish().
    private func startFile(_ url: URL, analyzer: SpeechAnalyzer, transcriber: DictationTranscriber,
                           status: (String) -> Void) async throws {
        status("Leser lydfil …")
        fileSeconds = try AudioFileDecoder.duration(of: url)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DiktatError(message: "Fant ikke et støttet lydformat.")
        }
        try await analyzer.prepareToAnalyze(in: format)
        try checkCancellation()
        let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .unbounded)
        try await analyzer.start(inputSequence: stream)
        do {
            try await AudioFileDecoder.decode(url, to: format) { buffer in
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
        } catch {
            continuation.finish(throwing: error)
            throw error
        }
        try checkCancellation()
        continuation.finish()
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
        stopAudio()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        try await resultsTask?.value
        try checkCancellation()
        return buffer.text
    }

    func cancel() async {
        cancelled = true
        stopAudio()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
    }
}
