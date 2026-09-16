import AVFoundation
import Speech
import Foundation

@MainActor
final class AppleSpeechSession: DictationSession {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var feed: AudioFeed?
    private var resultsTask: Task<Void, Error>?
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false
    private var cancelled = false
    private var buffer = TranscriptBuffer()
    var onLevel: ((Float) -> Void)?
    var onText: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?
    var processingProgress: Double { 0 } // Apple exposes no finalization progress.
    var finalizationTimeout: Double { 30 }

    func start(locale identifier: String, status: (String) -> Void) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw DiktatError(message: "Mikrofontilgang mangler. Åpne Systeminnstillinger → Personvern og sikkerhet → Mikrofon.")
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
        status("Klargjør mikrofon …")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else {
            throw DiktatError(message: "Ingen tilgjengelig mikrofon.")
        }
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
        try await analyzer.start(inputSequence: stream)
        try checkCancellation()
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: input, block: feed.makeTap())
        tapInstalled = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.followInputChange()
            }
        }
        engine.prepare()
        try engine.start()
    }

    // The engine stops when the input device changes (e.g. a headset connects).
    // Re-tap the new device and keep recording instead of failing the session.
    private func followInputChange() {
        guard !cancelled, tapInstalled, let feed else { return }
        engine.inputNode.removeTap(onBus: 0)
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else {
            tapInstalled = false
            onFailure?(DiktatError(message: "Mikrofonen ble koblet fra. Tilgjengelig tekst er bevart."))
            return
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: input, block: feed.makeTap())
        do { try engine.start() }
        catch { onFailure?(DiktatError(message: "Mikrofonen ble endret og kunne ikke startes igjen. Tilgjengelig tekst er bevart.")) }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func stopAudio() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
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
