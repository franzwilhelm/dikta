import Foundation

@MainActor
protocol DictationSession: AnyObject {
    var onText: ((String) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var processingProgress: Double { get }
    var finalizationTimeout: Double { get }
    func start(locale: String, status: (String) -> Void) async throws
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
        set { backend.onText = newValue }
    }
    var onFailure: ((Error) -> Void)? {
        get { backend.onFailure }
        set { backend.onFailure = newValue }
    }
    var onStatus: ((String) -> Void)? {
        get { backend.onStatus }
        set { backend.onStatus = newValue }
    }
    var onLevel: ((Float) -> Void)? {
        get { backend.onLevel }
        set { backend.onLevel = newValue }
    }
    var processingProgress: Double { backend.processingProgress }
    var finalizationTimeout: Double { backend.finalizationTimeout }
    func start(locale: String, status: (String) -> Void) async throws {
        try await backend.start(locale: locale, status: status)
    }
    func finish() async throws -> String { try await backend.finish() }
    func cancel() async { await backend.cancel() }
}
