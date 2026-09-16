import AVFoundation
import Foundation
import Speech

struct DiktatError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// AVAudioConverter's callback is Sendable; this object owns the buffer only
// for the synchronous conversion and guards one-shot delivery explicitly.
private final class ConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}

// AVAudioEngine invokes the tap serially. The lock also synchronizes shutdown
// with an in-flight callback, so the final audio is yielded before stream finish.
final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter
    private let format: AVAudioFormat
    private let consume: @Sendable (AVAudioPCMBuffer) throws -> Void
    private let end: @Sendable (Error?) -> Void
    private var ended = false
    private var meterSeconds = 0.0
    private let level: @Sendable (Float) -> Void

    init(input: AVAudioFormat, output: AVAudioFormat,
         level: @escaping @Sendable (Float) -> Void = { _ in },
         consume: @escaping @Sendable (AVAudioPCMBuffer) throws -> Void,
         end: @escaping @Sendable (Error?) -> Void) throws {
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw DiktatError(message: "Mikrofonens lydformat kan ikke konverteres.")
        }
        self.level = level
        self.converter = converter
        self.format = output
        self.consume = consume
        self.end = end
    }

    // Construct this callback outside MainActor. AVAudioNodeTapBlock does not
    // express its background execution in its type; creating it in start()
    // inherits MainActor and traps as soon as the audio thread calls it.
    func makeTap() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in receive(buffer) }
    }

    func receive(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        // The input device can change mid-session (e.g. a headset connects); follow its format.
        if input.format != converter.inputFormat {
            guard let replacement = AVAudioConverter(from: input.format, to: format) else {
                fail(DiktatError(message: "Mikrofonens lydformat kan ikke konverteres."))
                return
            }
            converter = replacement
        }
        meterSeconds += Double(input.frameLength) / input.format.sampleRate
        if meterSeconds >= 0.05, let channel = input.floatChannelData?[0], input.frameLength > 0 {
            meterSeconds = 0
            var sum: Float = 0
            for i in 0..<Int(input.frameLength) { sum += channel[i] * channel[i] }
            let rms = sqrt(sum / Float(input.frameLength))
            level(min(1, max(0, (20 * log10(max(rms, 0.00001)) + 60) / 60)))
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            fail(DiktatError(message: "Kunne ikke opprette lydbuffer."))
            return
        }
        let source = ConverterInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            source.take(status: state)
        }
        if status == .error {
            fail(error ?? DiktatError(message: "Lydkonverteringen feilet.") as NSError)
            return
        }
        if output.frameLength > 0 {
            do { try consume(output) }
            catch { fail(error) }
        }
    }

    private func fail(_ error: Error) {
        ended = true
        end(error)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        // Drain any samples retained by the sample-rate converter.
        var error: NSError?
        if let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) {
            let status = converter.convert(to: output, error: &error) { _, state in
                state.pointee = .endOfStream
                return nil
            }
            if status == .error {
                fail(error ?? DiktatError(message: "Kunne ikke avslutte lydstrømmen.") as NSError)
                return
            }
            if output.frameLength > 0 {
                do { try consume(output) }
                catch { fail(error); return }
            }
        }
        ended = true
        end(nil)
    }
}
