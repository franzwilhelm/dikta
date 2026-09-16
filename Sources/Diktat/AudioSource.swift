import AVFoundation
import Foundation

enum AudioSource: Sendable {
    case microphone
    case file(URL)

    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}

// Decodes an audio file off the main actor and feeds converted buffers through
// the same AudioFeed path the microphone uses, so both engines see one format.
enum AudioFileDecoder {
    static func duration(of url: URL) throws -> Double {
        let file = try open(url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func open(_ url: URL) throws -> AVAudioFile {
        do { return try AVAudioFile(forReading: url) }
        catch { throw DiktatError(message: "Kunne ikke åpne lydfilen. Bruk m4a, mp3, wav, aiff eller caf.") }
    }

    static func decode(_ url: URL, to output: AVAudioFormat,
                       consume: @escaping @Sendable (AVAudioPCMBuffer) throws -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            let file = try open(url)
            let input = file.processingFormat
            guard input.sampleRate > 0, input.channelCount > 0 else {
                throw DiktatError(message: "Lydfilen inneholder ingen lyd.")
            }
            let failure = ErrorBox()
            let feed = try AudioFeed(input: input, output: output, consume: consume, end: { error in
                failure.store(error)
            })
            let frames: AVAudioFrameCount = 65_536
            while file.framePosition < file.length {
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames) else {
                    throw DiktatError(message: "Kunne ikke opprette lydbuffer.")
                }
                try file.read(into: buffer, frameCount: frames)
                if buffer.frameLength == 0 { break }
                feed.receive(buffer)
                if let error = failure.value { throw error }
            }
            feed.finish()
            if let error = failure.value { throw error }
        }.value
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func store(_ error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if let error { self.error = error }
    }
    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}
