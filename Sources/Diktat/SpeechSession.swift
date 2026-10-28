import Foundation

@MainActor
protocol DictationSession: AnyObject {
    var onText: ((String) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    // Audio capture stopped by itself; what was already heard can still be finished.
    var onInterrupted: ((Error) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onInput: ((InputDevice?, Bool) -> Void)? { get set }
    var processingProgress: Double { get }
    var finalizationTimeout: Double { get }
    func start(source: AudioSource, locale: String, archive: AudioArchive?, status: (String) -> Void) async throws
    func finish() async throws -> String
    func cancel() async
}

@MainActor
final class SpeechSession {
    private let backend: any DictationSession
    init(useNBWhisper: Bool = false) {
        if useNBWhisper { backend = WhisperSession() }
        else { backend = AppleSpeechSession() }
    }
    var onText: ((String) -> Void)? {
        get { backend.onText }
        set { backend.onText = newValue.map { deliver in { deliver(Vocabulary.format($0)) } } }
    }
    var onFailure: ((Error) -> Void)? {
        get { backend.onFailure }
        set { backend.onFailure = newValue }
    }
    var onInterrupted: ((Error) -> Void)? {
        get { backend.onInterrupted }
        set { backend.onInterrupted = newValue }
    }
    var onStatus: ((String) -> Void)? {
        get { backend.onStatus }
        set { backend.onStatus = newValue }
    }
    var onLevel: ((Float) -> Void)? {
        get { backend.onLevel }
        set { backend.onLevel = newValue }
    }
    var onInput: ((InputDevice?, Bool) -> Void)? {
        get { backend.onInput }
        set { backend.onInput = newValue }
    }
    var processingProgress: Double { backend.processingProgress }
    var finalizationTimeout: Double { backend.finalizationTimeout }
    func start(source: AudioSource, locale: String, archive: AudioArchive?, status: (String) -> Void) async throws {
        try await backend.start(source: source, locale: locale, archive: archive, status: status)
    }
    func finish() async throws -> String { Vocabulary.format(try await backend.finish()) }
    func cancel() async { await backend.cancel() }
}
